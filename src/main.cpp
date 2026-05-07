#include "lua_actor.h"
#include "platform.h"
#include "service_logger.h"
#include "skynet.h"

#include <csignal>
#include <cstdlib>
#include <string>

// ============================================================================
// Config from system environment variables:
//   SKYNET_THREAD  — worker count (default: 8)
//   SKYNET_PRELOAD — preload script path (default: "examples/preload.lua")
// ============================================================================

static int get_thread_count() {
    std::string val = skynet::platform::getenv_string("SKYNET_THREAD");
    if (!val.empty()) {
        int n = std::atoi(val.c_str());
        if (n > 0) return n;
    }
    return 8;
}

static std::string get_preload_script() {
    std::string val = skynet::platform::getenv_string("SKYNET_PRELOAD");
    if (!val.empty()) return val;
    return "examples/preload.lua";
}

// ============================================================================
// Bootstrap: logger -> preload service
// ============================================================================

static void bootstrap(skynet::ActorSystem& sys, const std::string& preload_script) {
    // 1. Logger (always first)
    auto logger = sys.spawn<skynet::ServiceLogger>();
    sys.register_name("logger", logger);

    // 2. Preload script configures paths and launches services.
    sys.spawn<skynet::LuaActor>(preload_script);
}

// ============================================================================
// main
// ============================================================================

int main() {
    int thread_count = get_thread_count();
    std::string preload_script = get_preload_script();

    skynet::ActorSystem sys(thread_count);

    std::printf("=== skynet-cpp ===\n");
    std::printf("Workers: %d\n", thread_count);
    std::printf("Preload: %s\n", preload_script.c_str());
    std::printf("Ctrl+C to stop.\n\n");

    bootstrap(sys, preload_script);

    // Graceful shutdown on Ctrl+C
    asio::signal_set signals(sys.io_context(), SIGINT);
    signals.async_wait([&sys](const asio::error_code&, int) {
        std::printf("\nShutting down...\n");
        sys.shutdown();
    });

    sys.run();
    return 0;
}
