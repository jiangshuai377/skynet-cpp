#include "skynet.h"
#include "network.h"
#include "platform.h"

#include <atomic>
#include <cassert>
#include <chrono>
#include <ctime>
#include <cstdlib>
#include <filesystem>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>

using namespace skynet;

namespace {

class UnitActor final : public Actor {
public:
    bool initialized = false;
    bool destroyed = false;
    int messages = 0;

protected:
    void on_init(std::string_view param) override {
        initialized = param == "unit";
        assert(handle() != 0);
        assert(gen_session() > 0);

        send(handle(), PTYPE_TEXT, std::string("self-send"));
        int session = send_request(handle(), PTYPE_TEXT, std::string("self-request"));
        assert(session > 0);

        Message original;
        original.source = handle();
        original.session = 77;
        reply(original, std::string("reply"));
        assert(timeout(std::chrono::milliseconds(1)) > 0);
    }

    void on_message(const Message& msg) override {
        ++messages;
        if (msg.has_data() && msg.type == PTYPE_TEXT) {
            (void)msg.get<std::string>();
        }
    }

    void on_destroy() override {
        destroyed = true;
    }
};

class LoggerActor final : public Actor {
protected:
    void on_message(const Message& msg) override {
        assert(msg.type == PTYPE_ERROR);
        if (msg.has_data()) {
            (void)msg.get<std::string>();
        }
    }
};

class ThrowActor final : public Actor {
protected:
    void on_message(const Message&) override {
        throw std::runtime_error("unit throw");
    }
};

class SlowActor final : public Actor {
protected:
    void on_message(const Message&) override {
        std::this_thread::sleep_for(std::chrono::milliseconds(5600));
    }
};

} // namespace

int main() {
    {
        std::string path_env = platform::getenv_string("PATH");
        if (path_env.empty()) {
            path_env = platform::getenv_string("Path");
        }
        assert(!path_env.empty());
        assert(platform::getenv_string("__SKYNET_CPP_UNIT_MISSING_ENV__").empty());
        assert(platform::profile_time_seconds() >= 0.0);
        assert(!platform::node_name().empty());
        assert(platform::local_time(std::time(nullptr)).tm_year >= 70);

        std::filesystem::path temp =
            std::filesystem::temp_directory_path() / "skynet_cpp_platform_unit.tmp";
        std::string error;
        assert(platform::write_file(temp.string(), "abc", false, &error));
        assert(platform::write_file(temp.string(), "def", true, &error));
        assert(std::filesystem::file_size(temp) == 6);
        std::filesystem::remove(temp);

    }

    {
        WorkerMonitor monitor;
        assert(monitor.check() == false);
        monitor.begin(1, 2);
        assert(monitor.check() == false);
        assert(monitor.check() == true);
        monitor.end();
        assert(monitor.check() == false);
    }

    {
        ActorSystem zero_workers(0);
        assert(zero_workers.actor_count() == 0);
        assert(zero_workers.find_name("missing") == 0);
        zero_workers.register_name("unit-name", 123);
        assert(zero_workers.find_name("unit-name") == 123);
        auto empty_paths = zero_workers.lua_path_config();
        assert(!empty_paths.path_base.empty());
        assert(empty_paths.path.empty());
        assert(empty_paths.cpath.empty());
        assert(empty_paths.service_path.empty());
        zero_workers.set_lua_path_base("unit/base//");
        assert(zero_workers.lua_path_base() == "unit/base");
        zero_workers.append_lua_path("");
        zero_workers.prepend_lua_path("");
        auto still_empty_paths = zero_workers.lua_path_config();
        assert(still_empty_paths.path.empty());
        zero_workers.prepend_lua_path("solo");
        auto solo_paths = zero_workers.lua_path_config();
        assert(solo_paths.path.find("solo/?.lua") != std::string::npos);
        zero_workers.append_lua_path("foo\\\\bar//");
        zero_workers.prepend_lua_path("pre");
        zero_workers.append_lua_cpath("native");
        zero_workers.append_lua_service_path("svc//");
        auto paths = zero_workers.lua_path_config();
        assert(paths.path.find("pre/?.lua") != std::string::npos);
        assert(paths.path.find("foo/bar/?.lua") != std::string::npos);
        assert(paths.path.find("foo/bar/?/init.lua") != std::string::npos);
        assert(paths.cpath.find("native/?.dll") != std::string::npos);
        assert(paths.cpath.find("native/?.so") != std::string::npos);
        assert(paths.service_path.find("svc/?.lua") != std::string::npos);
        zero_workers.error(0, "unit stderr path %d", 1);
        zero_workers.kill(9999);
        zero_workers.shutdown();
    }

    {
        ActorSystem direct(1);
        uint32_t pending = direct.spawn<UnitActor>("unit");
        direct.send(0, pending, PTYPE_TEXT, 0, std::string("queued-before-kill"));
        void* payload = std::malloc(8);
        assert(payload != nullptr);
        direct.send(0, pending, PTYPE_LUA, 0,
                    skynet::SeriData{payload, static_cast<size_t>(8)});
        direct.kill(pending);
        assert(direct.actor_count() == 0);
    }

    {
        ActorSystem net_system(1);
        uint32_t owner = net_system.spawn<UnitActor>("unit");

        auto listener = std::make_shared<TcpListener>(net_system, owner, 0, 701, "127.0.0.1", true);
        listener->start();
        assert(listener->get_connection(-1) == nullptr);
        listener->send(-1, "missing");
        listener->close_connection(-1);
        listener->stop();

        asio::ip::tcp::acceptor acceptor(
            net_system.io_context(),
            asio::ip::tcp::endpoint(asio::ip::make_address("127.0.0.1"), 0));
        asio::ip::tcp::socket client(net_system.io_context());
        asio::ip::tcp::socket server(net_system.io_context());
        client.connect(acceptor.local_endpoint());
        acceptor.accept(server);

        auto conn = std::make_shared<TcpConnection>(
            net_system, std::move(server), owner, 702, 703, true);
        conn->pause();
        net_system.io_context().run_for(std::chrono::milliseconds(10));
        net_system.io_context().restart();
        conn->resume();
        conn->send(std::string(ActorSystem::SEND_BUFFER_WARNING, 'w'));
        conn->shutdown_write();
        net_system.io_context().run_for(std::chrono::milliseconds(20));
        net_system.io_context().restart();
        conn->close();
        client.close();

        auto connector = std::make_shared<TcpConnector>(
            net_system, owner, "no-such-host.invalid", 1, true);
        connector->send("before-open");
        connector->close();
        connector->start();
        net_system.io_context().run_for(std::chrono::milliseconds(50));
        net_system.io_context().restart();

        auto udp = std::make_shared<UdpSocket>(net_system, owner, 0);
        udp->start();
        udp->send_to("udp-unit", "127.0.0.1", 9);
        net_system.io_context().run_for(std::chrono::milliseconds(20));
        net_system.io_context().restart();
        udp->stop();
        net_system.kill(owner);
    }

    ActorSystem system(1);
    uint32_t logger = system.spawn<LoggerActor>("");
    system.register_name("logger", logger);

    uint32_t actor = system.spawn<UnitActor>("unit");
    assert(actor != 0);
    assert(system.actor_count() == 2);
    system.register_name("unit-actor", actor);
    assert(system.find_name("unit-actor") == actor);
    system.error(actor, "unit logger path %d", 2);

    system.send(0, 999999, PTYPE_TEXT, 0, std::string("drop"));
    void* payload = std::malloc(4);
    assert(payload != nullptr);
    system.send(0, 999999, PTYPE_LUA, 0,
                skynet::SeriData{payload, static_cast<size_t>(4)});
    system.send(actor, 999998, PTYPE_TEXT, 123, std::string("missing-request"));

    uint32_t throwing = system.spawn<ThrowActor>("");
    system.send(actor, throwing, PTYPE_TEXT, 0, std::string("throw"));
    uint32_t overloaded = system.spawn<UnitActor>("unit");
    for (size_t i = 0; i < ActorSystem::OVERLOAD_THRESHOLD; ++i) {
        system.send(actor, overloaded, PTYPE_TEXT, 0, std::string("overload"));
    }
    uint32_t slow = system.spawn<SlowActor>("");
    system.send(actor, slow, PTYPE_TEXT, 0, std::string("slow"));

    std::jthread runner([&](std::stop_token) {
        system.run();
    });
    std::this_thread::sleep_for(std::chrono::milliseconds(6200));
    system.kill(actor);
    system.kill(overloaded);
    system.kill(throwing);
    system.kill(slow);
    system.kill(logger);
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    system.shutdown();
    runner.join();

    system.shutdown();
    return 0;
}
