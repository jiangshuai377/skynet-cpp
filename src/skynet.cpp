#include "platform.h"
#include "skynet.h"
#include <cstdlib>
#include <cstring>
#include <mutex>

namespace skynet {

static std::string normalize_lua_dir(std::string path) {
    for (auto& c : path) {
        if (c == '\\') c = '/';
    }
    while (path.size() > 1 && path.back() == '/') {
        path.pop_back();
    }
    std::string out;
    out.reserve(path.size());
    bool prev_slash = false;
    for (char c : path) {
        bool slash = c == '/';
        if (slash && prev_slash) {
            continue;
        }
        out.push_back(c);
        prev_slash = slash;
    }
    return out;
}

static void append_segment(std::string& target, const std::string& segment) {
    if (segment.empty()) {
        return;
    }
    if (!target.empty()) {
        target += ';';
    }
    target += segment;
}

static void prepend_segment(std::string& target, const std::string& segment) {
    if (segment.empty()) {
        return;
    }
    if (target.empty()) {
        target = segment;
    } else {
        target = segment + ';' + target;
    }
}

static std::string lua_path_pattern(const std::string& dir) {
    return dir + "/?.lua;" + dir + "/?/init.lua";
}

static std::string lua_cpath_pattern(const std::string& dir) {
    return dir + "/?.dll;" + dir + "/?/?.dll;" +
           dir + "/?.so;" + dir + "/?/?.so";
}

static std::string service_path_pattern(const std::string& dir) {
    return dir + "/?.lua";
}

static void free_owned_message_data(Message& msg) {
    if (auto* sd = std::get_if<SeriData>(&msg.data)) {
        std::free(sd->data);
        sd->data = nullptr;
        sd->size = 0;
    }
}

// ============================================================================
// Actor convenience methods
// ============================================================================

void Actor::send(uint32_t dest, int type, MessagePayload data) {
    system_->send(handle_, dest, type, 0, std::move(data));
}

int Actor::send_request(uint32_t dest, int type, MessagePayload data) {
    int session = alloc_session();
    system_->send(handle_, dest, type, session, std::move(data));
    return session;
}

void Actor::reply(const Message& original, MessagePayload data) {
    system_->send(handle_, original.source, PTYPE_RESPONSE,
                  original.session, std::move(data));
}

int Actor::timeout(std::chrono::milliseconds delay) {
    int session = alloc_session();
    system_->timeout(handle_, session, delay);
    return session;
}

// ============================================================================
// ActorSystem
// ============================================================================

ActorSystem::ActorSystem(int worker_count)
    : worker_count_(worker_count > 0
                        ? worker_count
                        : static_cast<int>(
                              std::thread::hardware_concurrency())) {
    lua_paths_.path_base = normalize_lua_dir(platform::current_path());
}

ActorSystem::~ActorSystem() { shutdown(); }

// -- actor lifecycle ---------------------------------------------------------

void ActorSystem::kill(uint32_t handle) {
    std::shared_ptr<ActorQueue> queue;
    {
        auto& shard = actor_shard(handle);
        std::unique_lock lock(shard.mutex);
        auto it = shard.queues.find(handle);
        if (it == shard.queues.end()) return;
        queue = std::move(it->second);
        shard.queues.erase(it);
    }
    uint32_t logger = logger_handle_.load(std::memory_order_acquire);
    if (logger == handle) {
        logger_handle_.compare_exchange_strong(
            logger, 0, std::memory_order_acq_rel);
    }
    queue->accepting.store(false, std::memory_order_release);
    queue->releasing.store(true, std::memory_order_release);

    auto actor = queue_owner(queue);
    if (actor) {
        actor->destroy_requested_.store(true, std::memory_order_release);
        if (actor->dispatch_depth_.load(std::memory_order_acquire) == 0) {
            drain_queue(queue);
            destroy_actor(actor);
            clear_queue_owner(queue, actor);
            queue->schedule_state.store(0, std::memory_order_seq_cst);
            return;
        }
    }
    schedule_queue(queue);
}

// -- messaging ---------------------------------------------------------------

void ActorSystem::send(uint32_t source, uint32_t dest, int type,
                       int session, MessagePayload data) {
    Message msg;
    msg.source  = source;
    msg.session = session;
    msg.type    = type;
    msg.data    = std::move(data);
    push_message(dest, std::move(msg));
}

void ActorSystem::push_message(uint32_t dest, Message msg) {
    auto queue = grab_queue(dest);
    if (!queue || !queue->accepting.load(std::memory_order_acquire)) {
        if (msg.session != 0 && msg.source != 0 &&
            msg.type != PTYPE_RESPONSE && msg.type != PTYPE_ERROR) {
            send(0, msg.source, PTYPE_ERROR, msg.session, {});
        }
        free_owned_message_data(msg);
        return;
    }

    queue->mailbox.enqueue(std::move(msg));
    size_t qsize = queue->mailbox_count.fetch_add(
        1, std::memory_order_acq_rel) + 1;

    size_t threshold = queue->overload_threshold.load(std::memory_order_relaxed);
    while (qsize >= threshold) {
        size_t next = threshold > (static_cast<size_t>(-1) / 2)
            ? static_cast<size_t>(-1)
            : threshold * 2;
        if (queue->overload_threshold.compare_exchange_weak(
                threshold, next, std::memory_order_relaxed)) {
            error(dest, "mailbox overloaded: ~%zu pending messages", qsize);
            break;
        }
    }

    if (!queue->initialized.load(std::memory_order_acquire)) {
        return;
    }

    schedule_queue(queue);
}

// -- error reporting ---------------------------------------------------------

void ActorSystem::error(uint32_t source, const char* fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    int n = std::vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n < 0) return;

    std::string text(buf, static_cast<size_t>(
        n < static_cast<int>(sizeof(buf)) ? n : sizeof(buf) - 1));

    uint32_t logger_handle = logger_handle_.load(std::memory_order_acquire);
    if (logger_handle == 0) {
        logger_handle = find_name("logger");
        if (logger_handle != 0) {
            logger_handle_.store(logger_handle, std::memory_order_release);
        }
    }
    if (logger_handle != 0) {
        Message msg;
        msg.source  = source;
        msg.session = 0;
        msg.type    = PTYPE_ERROR;
        msg.data    = std::move(text);
        push_message(logger_handle, std::move(msg));
    } else {
        std::fprintf(stderr, "[%08x] ERROR: %s\n", source, text.c_str());
    }
}

// -- named services ----------------------------------------------------------

void ActorSystem::register_name(const std::string& name, uint32_t handle) {
    std::unique_lock lock(names_mutex_);
    names_[name] = handle;
    if (name == "logger") {
        logger_handle_.store(handle, std::memory_order_release);
    }
}

uint32_t ActorSystem::find_name(const std::string& name) const {
    std::shared_lock lock(names_mutex_);
    auto it = names_.find(name);
    return it != names_.end() ? it->second : 0;
}

// -- Lua runtime path configuration -----------------------------------------

ActorSystem::LuaPathConfig ActorSystem::lua_path_config() const {
    std::shared_lock lock(lua_paths_mutex_);
    return lua_paths_;
}

std::string ActorSystem::lua_path_base() const {
    std::shared_lock lock(lua_paths_mutex_);
    return lua_paths_.path_base;
}

void ActorSystem::set_lua_path_base(const std::string& path) {
    std::string dir = normalize_lua_dir(path);
    if (dir.empty()) return;
    std::unique_lock lock(lua_paths_mutex_);
    lua_paths_.path_base = std::move(dir);
}

void ActorSystem::append_lua_path(const std::string& path) {
    std::string dir = normalize_lua_dir(path);
    if (dir.empty()) return;
    std::unique_lock lock(lua_paths_mutex_);
    append_segment(lua_paths_.path, lua_path_pattern(dir));
}

void ActorSystem::prepend_lua_path(const std::string& path) {
    std::string dir = normalize_lua_dir(path);
    if (dir.empty()) return;
    std::unique_lock lock(lua_paths_mutex_);
    prepend_segment(lua_paths_.path, lua_path_pattern(dir));
}

void ActorSystem::append_lua_cpath(const std::string& path) {
    std::string dir = normalize_lua_dir(path);
    if (dir.empty()) return;
    std::unique_lock lock(lua_paths_mutex_);
    append_segment(lua_paths_.cpath, lua_cpath_pattern(dir));
}

void ActorSystem::append_lua_service_path(const std::string& path) {
    std::string dir = normalize_lua_dir(path);
    if (dir.empty()) return;
    std::unique_lock lock(lua_paths_mutex_);
    append_segment(lua_paths_.service_path, service_path_pattern(dir));
}

// -- timer -------------------------------------------------------------------

void ActorSystem::timeout(uint32_t dest, int session,
                          std::chrono::milliseconds delay) {
    if (delay.count() <= 0) {
        send(0, dest, PTYPE_RESPONSE, session, {});
        return;
    }

    auto timer = std::make_shared<asio::steady_timer>(io_ctx_, delay);
    timer->async_wait(
        [this, dest, session, timer](const asio::error_code& ec) {
            if (!ec) {
                send(0, dest, PTYPE_RESPONSE, session, {});
            }
        });
}

// -- queries -----------------------------------------------------------------

size_t ActorSystem::actor_count() const {
    size_t count = 0;
    for (const auto& shard : actor_shards_) {
        std::shared_lock lock(shard.mutex);
        count += shard.queues.size();
    }
    return count;
}

ActorSystem::SystemStats ActorSystem::stats() const {
    SystemStats s;
    s.running = running_.load(std::memory_order_relaxed);
    s.worker_count = worker_count_;
    s.global_queue_count = global_queue_count_.load(std::memory_order_relaxed);
    s.sleeping_workers = sleeping_workers_.load(std::memory_order_relaxed);
    s.global_queue_epoch = global_queue_epoch_.load(std::memory_order_relaxed);

    for (const auto& shard : actor_shards_) {
        std::shared_lock lock(shard.mutex);
        s.actor_count += shard.queues.size();
        for (const auto& [handle, queue] : shard.queues) {
            (void)handle;
            if (!queue) {
                continue;
            }
            s.queued_messages += queue->mailbox_count.load(
                std::memory_order_relaxed);
            int state = queue->schedule_state.load(std::memory_order_relaxed);
            if (state != 0) {
                ++s.active_queues;
            }
            if (queue->releasing.load(std::memory_order_relaxed)) {
                ++s.releasing_queues;
            }
        }
    }
    return s;
}

// -- scheduling weight -------------------------------------------------------
//
// Original Skynet weight system:
//   weight -1 : process exactly 1 message per turn  (first 1/4 workers)
//   weight  0 : process ALL messages                 (second 1/4)
//   weight  1 : process n/2 messages                 (third 1/4)
//   weight  2 : process n/4 messages                 (last 1/4)
//
// This prevents fast actors from starving slow ones.

int ActorSystem::calc_weight(int worker_id) const {
    int quarter = worker_count_ / 4;
    if (quarter < 1) return 0;
    if (worker_id < quarter)       return -1;
    if (worker_id < quarter * 2)   return 0;
    if (worker_id < quarter * 3)   return 1;
    return 2;
}

// -- run / shutdown ----------------------------------------------------------

void ActorSystem::run() {
    running_.store(true, std::memory_order_release);

    io_work_.emplace(asio::make_work_guard(io_ctx_));
    io_thread_ = std::jthread([this](std::stop_token) { io_ctx_.run(); });

    // Initialize per-worker monitors
    monitors_.reserve(worker_count_);
    for (int i = 0; i < worker_count_; ++i)
        monitors_.push_back(std::make_unique<WorkerMonitor>());

    // Monitor thread (deadlock detection, every 5s)
    monitor_thread_ = std::jthread(
        [this](std::stop_token) { monitor_loop(); });

    // Worker threads
    workers_.reserve(worker_count_);
    for (int i = 0; i < worker_count_; ++i) {
        workers_.emplace_back(
            [this, i](std::stop_token) { worker_loop(i); });
    }

    for (auto& w : workers_) w.join();
    monitor_thread_.join();
    io_thread_.join();

    std::vector<std::shared_ptr<ActorQueue>> remaining;
    remaining.reserve(actor_count());
    for (auto& shard : actor_shards_) {
        std::unique_lock lock(shard.mutex);
        for (auto& [handle, queue] : shard.queues) {
            (void)handle;
            remaining.push_back(std::move(queue));
        }
        shard.queues.clear();
    }
    for (auto& queue : remaining) {
        queue->accepting.store(false, std::memory_order_release);
        queue->releasing.store(true, std::memory_order_release);
        auto actor = queue_owner(queue);
        if (actor) {
            actor->destroy_requested_.store(true, std::memory_order_release);
            destroy_actor(actor);
            clear_queue_owner(queue, actor);
        }
        drain_queue(queue);
    }
}

void ActorSystem::shutdown() {
    if (!running_.exchange(false)) return;

    io_work_.reset();
    io_ctx_.stop();

    for (int i = 0; i < worker_count_; ++i) {
        global_queue_.enqueue(nullptr);
        global_queue_count_.fetch_add(1, std::memory_order_release);
    }
    global_queue_epoch_.fetch_add(1, std::memory_order_release);
    global_queue_epoch_.notify_all();
}

// -- internal ----------------------------------------------------------------

void ActorSystem::push_global(uint32_t handle) {
    auto queue = grab_queue(handle);
    if (!queue) return;
    schedule_queue(queue);
}

std::shared_ptr<Actor> ActorSystem::queue_owner(
    const std::shared_ptr<ActorQueue>& queue) {
    if (!queue) return nullptr;
    std::lock_guard lock(queue->owner_mutex);
    return queue->owner;
}

void ActorSystem::clear_queue_owner(
    const std::shared_ptr<ActorQueue>& queue,
    const std::shared_ptr<Actor>& actor) {
    if (!queue) return;
    std::lock_guard lock(queue->owner_mutex);
    if (!actor || queue->owner == actor) {
        queue->owner.reset();
    }
}

void ActorSystem::schedule_queue(const std::shared_ptr<ActorQueue>& queue) {
    if (!queue || !queue->initialized.load(std::memory_order_acquire)) {
        return;
    }
    int expected = 0;
    if (queue->schedule_state.compare_exchange_strong(
            expected, 1, std::memory_order_seq_cst)) {
        enqueue_global(queue);
    }
}

void ActorSystem::enqueue_global(const std::shared_ptr<ActorQueue>& queue) {
    global_queue_.enqueue(queue);
    int queued = global_queue_count_.fetch_add(
        1, std::memory_order_acq_rel) + 1;
    int sleeping = sleeping_workers_.load(std::memory_order_relaxed);
    if (sleeping > 0 && queued <= sleeping) {
        global_queue_epoch_.fetch_add(1, std::memory_order_release);
        global_queue_epoch_.notify_one();
    }
}

void ActorSystem::destroy_actor(const std::shared_ptr<Actor>& actor) {
    if (!actor) return;
    if (!actor->destroyed_.exchange(true, std::memory_order_acq_rel)) {
        actor->on_destroy();
    }
}

void ActorSystem::drain_queue(const std::shared_ptr<ActorQueue>& queue) {
    if (!queue) return;
    Message msg;
    while (queue->mailbox.try_dequeue(msg)) {
        queue->mailbox_count.fetch_sub(1, std::memory_order_acq_rel);
        if (msg.session != 0 && msg.source != 0 &&
            msg.type != PTYPE_RESPONSE && msg.type != PTYPE_ERROR) {
            send(0, msg.source, PTYPE_ERROR, msg.session, {});
        }
        free_owned_message_data(msg);
    }
    queue->mailbox_count.store(0, std::memory_order_release);
}

std::shared_ptr<ActorSystem::ActorQueue> ActorSystem::grab_queue(uint32_t handle) {
    const auto& shard = actor_shard(handle);
    std::shared_lock lock(shard.mutex);
    auto it = shard.queues.find(handle);
    return it != shard.queues.end() ? it->second : nullptr;
}

void ActorSystem::worker_loop(int id) {
    int weight = calc_weight(id);
    int idle_spin = worker_count_ <= 8 ? 256 : (worker_count_ <= 16 ? 64 : 0);
    std::shared_ptr<ActorQueue> queue;
    auto try_dequeue_global = [this, &queue]() {
        if (!global_queue_.try_dequeue(queue)) {
            return false;
        }
        global_queue_count_.fetch_sub(1, std::memory_order_acq_rel);
        return true;
    };
    while (running_.load(std::memory_order_relaxed)) {
        if (!queue && !try_dequeue_global()) {
            for (int spin = 0; spin < idle_spin && running_.load(std::memory_order_relaxed); ++spin) {
                std::atomic_signal_fence(std::memory_order_seq_cst);
                if (try_dequeue_global()) {
                    break;
                }
            }
            if (queue) {
                dispatch_queue(queue, weight, *monitors_[id]);
                continue;
            }
            auto epoch = global_queue_epoch_.load(std::memory_order_acquire);
            sleeping_workers_.fetch_add(1, std::memory_order_relaxed);
            if (!try_dequeue_global()) {
                global_queue_epoch_.wait(epoch, std::memory_order_acquire);
            }
            sleeping_workers_.fetch_sub(1, std::memory_order_relaxed);
            continue;
        }
        if (queue) {
            dispatch_queue(queue, weight, *monitors_[id]);
        }
    }
}

void ActorSystem::dispatch_queue(std::shared_ptr<ActorQueue>& queue,
                                 int weight, WorkerMonitor& mon) {
    if (!queue) {
        return;
    }
    auto current = queue;
    int state = current->schedule_state.load(std::memory_order_acquire);
    if (state == 1) {
        int queued = 1;
        if (!current->schedule_state.compare_exchange_strong(
                queued, 2, std::memory_order_acq_rel)) {
            queue.reset();
            return;
        }
    } else if (state != 2) {
        queue.reset();
        return;
    }

    auto actor = queue_owner(current);
    if (!actor) {
        drain_queue(current);
        current->schedule_state.store(0, std::memory_order_seq_cst);
        queue.reset();
        return;
    }

    actor->dispatch_depth_.fetch_add(1, std::memory_order_acq_rel);
    if (current->releasing.load(std::memory_order_acquire) ||
        actor->destroy_requested_.load(std::memory_order_acquire)) {
        drain_queue(current);
        current->schedule_state.store(0, std::memory_order_seq_cst);
        if (actor->dispatch_depth_.fetch_sub(1, std::memory_order_acq_rel) == 1) {
            destroy_actor(actor);
            clear_queue_owner(current, actor);
        }
        queue.reset();
        return;
    }

    Message msg;

    // Determine batch size based on weight
    size_t qsize = current->mailbox_count.load(std::memory_order_acquire);
    size_t batch;
    if (weight < 0) {
        batch = 1;                       // -1: exactly one message
    } else if (weight == 0) {
        batch = qsize > 0 ? qsize : 1;  //  0: drain all
    } else {
        batch = qsize >> weight;         //  1: half, 2: quarter
        if (batch < 1) batch = 1;
    }

    size_t count = 0;
    while (count < batch &&
           !actor->destroy_requested_.load(std::memory_order_acquire) &&
           !current->releasing.load(std::memory_order_acquire) &&
           current->mailbox.try_dequeue(msg)) {
        current->mailbox_count.fetch_sub(1, std::memory_order_acq_rel);
        mon.begin(msg.source, current->handle);
        try {
            actor->on_message(msg);
        } catch (const std::exception& e) {
            error(current->handle, "exception: %s", e.what());
        }
        mon.end();
        ++count;
    }

    std::shared_ptr<ActorQueue> next_queue = current;
    if (current->releasing.load(std::memory_order_acquire) ||
        actor->destroy_requested_.load(std::memory_order_acquire)) {
        drain_queue(current);
        current->schedule_state.store(0, std::memory_order_seq_cst);
        next_queue.reset();
    } else if (current->mailbox_count.load(std::memory_order_acquire) > 0) {
        current->schedule_state.store(1, std::memory_order_seq_cst);
        enqueue_global(current);
        next_queue.reset();
    } else {
        current->schedule_state.store(0, std::memory_order_seq_cst);
        current->overload_threshold.store(
            OVERLOAD_THRESHOLD, std::memory_order_relaxed);
        if (!actor->destroy_requested_.load(std::memory_order_acquire) &&
            !current->releasing.load(std::memory_order_acquire) &&
            current->mailbox_count.load(std::memory_order_seq_cst) > 0) {
            schedule_queue(current);
        }
        next_queue.reset();
    }

    if (actor->dispatch_depth_.fetch_sub(1, std::memory_order_acq_rel) == 1 &&
        (actor->destroy_requested_.load(std::memory_order_acquire) ||
         current->releasing.load(std::memory_order_acquire))) {
        destroy_actor(actor);
        clear_queue_owner(current, actor);
    }
    queue = std::move(next_queue);
}

// -- monitor thread ----------------------------------------------------------

void ActorSystem::monitor_loop() {
    while (running_.load(std::memory_order_relaxed)) {
        // Sleep 5 seconds (check running_ periodically)
        for (int i = 0; i < 50 && running_.load(std::memory_order_relaxed); ++i) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
        if (!running_.load(std::memory_order_relaxed)) break;

        for (int i = 0; i < worker_count_; ++i) {
            auto& mon = *monitors_[i];
            if (mon.check()) {
                uint32_t src = mon.source.load(std::memory_order_relaxed);
                uint32_t dst = mon.destination.load(std::memory_order_relaxed);
                if (dst != 0) {
                    error(dst, "worker #%d may be stuck: "
                          "processing msg from %08x -> %08x",
                          i, src, dst);
                }
            }
        }
    }
}

} // namespace skynet
