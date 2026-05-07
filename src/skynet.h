#pragma once

#include <array>
#include <atomic>
#include <chrono>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <shared_mutex>
#include <string>
#include <string_view>
#include <thread>
#include <type_traits>
#include <unordered_map>
#include <variant>
#include <vector>

#include <asio.hpp>
#include <blockingconcurrentqueue.h>
#include <concurrentqueue.h>

namespace skynet {

// ============================================================================
// Message Types (compatible with original Skynet PTYPE)
// ============================================================================

enum MessageType : int {
    PTYPE_TEXT     = 0,
    PTYPE_RESPONSE = 1,
    PTYPE_MULTICAST = 2,
    PTYPE_CLIENT   = 3,
    PTYPE_SYSTEM   = 4,
    PTYPE_HARBOR   = 5,
    PTYPE_SOCKET   = 6,
    PTYPE_ERROR    = 7,
    PTYPE_TIMER    = 8,
    PTYPE_DEBUG    = 9,
    PTYPE_LUA      = 10,
    PTYPE_SNAX     = 11,
    PTYPE_TRACE    = 12,
};

// ============================================================================
// Message payloads
// ============================================================================

struct SeriData {
    void*  data = nullptr;
    size_t size = 0;
};

struct SocketAccept {
    int         listener_id;
    int         connection_id;
    std::string remote_address;
    uint16_t    remote_port;
};

struct SocketData {
    int         listener_id;
    int         connection_id;
    std::string data;
};

struct SocketClose {
    int listener_id;
    int connection_id;
};

struct SocketOpen {
    int         connection_id;
    std::string remote_address;
    uint16_t    remote_port;
};

struct SocketWarning {
    int    listener_id;
    int    connection_id;
    size_t pending_bytes;
};

struct SocketUDP {
    int         socket_id;
    std::string data;
    std::string remote_address;
    uint16_t    remote_port;
};

using MessagePayload = std::variant<std::monostate, std::string, SeriData,
                                    SocketAccept, SocketData, SocketClose,
                                    SocketOpen, SocketWarning, SocketUDP>;

// ============================================================================
// Message
// ============================================================================

struct Message {
    uint32_t source  = 0;
    int      session = 0;
    int      type    = PTYPE_TEXT;
    MessagePayload data;

    template <typename T>
    const T& get() const { return std::get<T>(data); }

    template <typename T>
    T& get() { return std::get<T>(data); }

    template <typename T>
    const T* get_if() const { return std::get_if<T>(&data); }

    template <typename T>
    T* get_if() { return std::get_if<T>(&data); }

    bool has_data() const { return !std::holds_alternative<std::monostate>(data); }
};

// ============================================================================
// Forward declarations
// ============================================================================

class ActorSystem;

// ============================================================================
// Actor
// ============================================================================

class Actor : public std::enable_shared_from_this<Actor> {
public:
    virtual ~Actor() = default;

    uint32_t     handle() const { return handle_; }
    ActorSystem& system()       { return *system_; }

    void send(uint32_t dest, int type, MessagePayload data = {});
    int  send_request(uint32_t dest, int type, MessagePayload data = {});
    void reply(const Message& original, MessagePayload data = {});
    int  timeout(std::chrono::milliseconds delay);
    int  gen_session() { return alloc_session(); }

protected:
    virtual void on_init(std::string_view param) { (void)param; }
    virtual void on_message(const Message& msg) = 0;
    virtual void on_destroy() {}

    void mark_init_failed() {
        init_failed_.store(true, std::memory_order_release);
    }

private:
    friend class ActorSystem;

    uint32_t     handle_  = 0;
    ActorSystem* system_  = nullptr;

    std::atomic<int>  next_session_{1};
    std::atomic<int>  dispatch_depth_{0};
    std::atomic<bool> destroy_requested_{false};
    std::atomic<bool> destroyed_{false};
    std::atomic<bool> init_failed_{false};

    int alloc_session() {
        return next_session_.fetch_add(1, std::memory_order_relaxed);
    }
};

// ============================================================================
// WorkerMonitor -- per-worker deadlock detection
//
// Each worker sets source/destination before dispatching.
// Monitor thread checks every 5s: if version unchanged, worker is stuck.
// ============================================================================

struct WorkerMonitor {
    std::atomic<uint32_t> version{0};
    std::atomic<uint32_t> check_version{0};
    std::atomic<uint32_t> source{0};
    std::atomic<uint32_t> destination{0};
    std::atomic<bool>     busy{false};  // true while dispatching

    void begin(uint32_t src, uint32_t dst) {
        source.store(src, std::memory_order_relaxed);
        destination.store(dst, std::memory_order_relaxed);
        version.fetch_add(1, std::memory_order_relaxed);
        busy.store(true, std::memory_order_release);
    }

    void end() {
        busy.store(false, std::memory_order_release);
    }

    // Returns true if worker appears stuck (busy and version unchanged)
    bool check() {
        if (!busy.load(std::memory_order_acquire)) {
            check_version.store(version.load(std::memory_order_relaxed),
                                std::memory_order_relaxed);
            return false;  // idle -- not stuck
        }
        uint32_t v  = version.load(std::memory_order_relaxed);
        uint32_t cv = check_version.load(std::memory_order_relaxed);
        if (v == cv) return true;   // busy and version unchanged = stuck
        check_version.store(v, std::memory_order_relaxed);
        return false;
    }
};

// ============================================================================
// ActorSystem
// ============================================================================

class ActorSystem {
public:
    static constexpr size_t OVERLOAD_THRESHOLD    = 1024;
    static constexpr size_t SEND_BUFFER_WARNING   = 1024 * 1024; // 1 MB

    struct LuaPathConfig {
        std::string path_base;
        std::string path;
        std::string cpath;
        std::string service_path;
    };

    explicit ActorSystem(int worker_count = 0);
    ~ActorSystem();

    ActorSystem(const ActorSystem&)            = delete;
    ActorSystem& operator=(const ActorSystem&) = delete;

    // -- actor lifecycle --

    template <typename T, typename... Args>
    uint32_t spawn(std::string_view param = "", Args&&... args);

    void kill(uint32_t handle);

    // -- messaging --

    void send(uint32_t source, uint32_t dest, int type, int session,
              MessagePayload data);

    // -- error reporting (routes PTYPE_ERROR to "logger" actor) --

    void error(uint32_t source, const char* fmt, ...);

    // -- named services --

    void     register_name(const std::string& name, uint32_t handle);
    uint32_t find_name(const std::string& name) const;

    // -- Lua runtime path configuration --

    LuaPathConfig lua_path_config() const;
    std::string lua_path_base() const;
    void set_lua_path_base(const std::string& path);
    void append_lua_path(const std::string& path);
    void prepend_lua_path(const std::string& path);
    void append_lua_cpath(const std::string& path);
    void append_lua_service_path(const std::string& path);

    // -- timer --

    void timeout(uint32_t dest, int session, std::chrono::milliseconds delay);

    // -- io_context --

    asio::io_context& io_context() { return io_ctx_; }

    // -- lifecycle --

    size_t actor_count() const;
    void   run();
    void   shutdown();
    bool   is_running() const {
        return running_.load(std::memory_order_relaxed);
    }

private:
    static constexpr size_t ACTOR_SHARD_COUNT = 64;

    struct ActorQueue {
        uint32_t handle = 0;

        moodycamel::ConcurrentQueue<Message> mailbox;
        std::atomic<size_t> mailbox_count{0};
        std::atomic<size_t> overload_threshold{OVERLOAD_THRESHOLD};
        // 0 idle, 1 queued in global queue, 2 currently dispatching.
        std::atomic<int> schedule_state{0};
        std::atomic<bool> accepting{true};
        std::atomic<bool> releasing{false};
        std::atomic<bool> initialized{false};

        mutable std::mutex owner_mutex;
        std::shared_ptr<Actor> owner;
    };

    struct ActorShard {
        mutable std::shared_mutex mutex;
        std::unordered_map<uint32_t, std::shared_ptr<ActorQueue>> queues;
    };

    ActorShard& actor_shard(uint32_t handle) {
        return actor_shards_[handle & (ACTOR_SHARD_COUNT - 1)];
    }

    const ActorShard& actor_shard(uint32_t handle) const {
        return actor_shards_[handle & (ACTOR_SHARD_COUNT - 1)];
    }

    void                        push_global(uint32_t handle);
    std::shared_ptr<ActorQueue> grab_queue(uint32_t handle);
    std::shared_ptr<Actor>      queue_owner(
        const std::shared_ptr<ActorQueue>& queue);
    void                        clear_queue_owner(
        const std::shared_ptr<ActorQueue>& queue,
        const std::shared_ptr<Actor>& actor);
    void                        schedule_queue(
        const std::shared_ptr<ActorQueue>& queue);
    void                        enqueue_global(
        const std::shared_ptr<ActorQueue>& queue);
    void                   worker_loop(int id);
    void                   dispatch_queue(std::shared_ptr<ActorQueue>& queue,
                                          int weight, WorkerMonitor& mon);
    void                   push_message(uint32_t dest, Message msg);
    void                   destroy_actor(const std::shared_ptr<Actor>& actor);
    void                   drain_queue(const std::shared_ptr<ActorQueue>& queue);
    void                   monitor_loop();
    int                    calc_weight(int worker_id) const;

    std::atomic<uint32_t> next_handle_{1};

    std::array<ActorShard, ACTOR_SHARD_COUNT> actor_shards_;

    mutable std::shared_mutex names_mutex_;
    std::unordered_map<std::string, uint32_t> names_;
    std::atomic<uint32_t> logger_handle_{0};

    mutable std::shared_mutex lua_paths_mutex_;
    LuaPathConfig lua_paths_;

    moodycamel::ConcurrentQueue<std::shared_ptr<ActorQueue>> global_queue_;
    std::atomic<int>        global_queue_count_{0};
    std::atomic<uint64_t>   global_queue_epoch_{0};
    std::atomic<int>        sleeping_workers_{0};

    asio::io_context io_ctx_;
    using work_guard_t =
        asio::executor_work_guard<asio::io_context::executor_type>;
    std::optional<work_guard_t> io_work_;

    std::vector<std::jthread>  workers_;
    std::jthread               io_thread_;
    std::jthread               monitor_thread_;
    std::atomic<bool>          running_{false};
    int                        worker_count_;

    std::vector<std::unique_ptr<WorkerMonitor>> monitors_;
};

// ============================================================================
// ActorSystem::spawn  (template)
// ============================================================================

template <typename T, typename... Args>
uint32_t ActorSystem::spawn(std::string_view param, Args&&... args) {
    static_assert(std::is_base_of_v<Actor, T>, "T must derive from Actor");

    auto     actor  = std::make_shared<T>(std::forward<Args>(args)...);
    auto     queue  = std::make_shared<ActorQueue>();
    uint32_t handle = next_handle_.fetch_add(1, std::memory_order_relaxed);

    actor->handle_ = handle;
    actor->system_ = this;
    queue->handle = handle;
    queue->owner = actor;

    {
        auto& shard = actor_shard(handle);
        std::unique_lock lock(shard.mutex);
        shard.queues[handle] = queue;
    }

    try {
        static_cast<Actor*>(actor.get())->on_init(param);
    } catch (const std::exception& e) {
        error(handle, "actor init failed: %s", e.what());
        actor->mark_init_failed();
    } catch (...) {
        error(handle, "actor init failed: unknown exception");
        actor->mark_init_failed();
    }
    if (actor->init_failed_.load(std::memory_order_acquire)) {
        {
            auto& shard = actor_shard(handle);
            std::unique_lock lock(shard.mutex);
            auto it = shard.queues.find(handle);
            if (it != shard.queues.end() && it->second == queue) {
                shard.queues.erase(it);
            }
        }
        queue->accepting.store(false, std::memory_order_release);
        queue->releasing.store(true, std::memory_order_release);
        drain_queue(queue);
        destroy_actor(actor);
        clear_queue_owner(queue, actor);
        return 0;
    }
    queue->initialized.store(true, std::memory_order_release);
    if (queue->mailbox_count.load(std::memory_order_acquire) > 0) {
        schedule_queue(queue);
    }
    return handle;
}

} // namespace skynet
