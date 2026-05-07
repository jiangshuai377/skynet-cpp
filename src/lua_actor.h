#pragma once

#include "skynet.h"
#include <string>

extern "C" {
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
}

namespace skynet {

// ============================================================================
// LuaActor -- each Lua service = one Actor + one lua_State
//
// Mirrors Skynet's service_snlua.c:
//   on_init(param) → loads Lua script via loader.lua
//   on_message()   → calls registered Lua callback (5 args: type, msg, sz, session, source)
//   on_destroy()   → lua_close(L)
// ============================================================================

class LuaActor : public Actor {
public:
    LuaActor();
    ~LuaActor() override;

    lua_State* lua_state() const { return L_; }
    void set_callback_ref(int ref);

    // Memory monitoring accessors
    size_t get_mem_used() const { return mem_; }
    size_t get_mem_limit() const { return mem_limit_; }
    void   set_mem_limit(size_t limit) { mem_limit_ = limit; }

protected:
    void on_init(std::string_view param) override;
    void on_message(const Message& msg) override;
    void on_destroy() override;

private:
    lua_State* L_ = nullptr;
    bool       has_callback_ = false;
    int        callback_ref_ = LUA_NOREF;
    int        traceback_ref_ = LUA_NOREF;

    // Memory tracking
    size_t mem_       = 0;
    size_t mem_limit_ = 0;
    size_t mem_report_ = 8 * 1024 * 1024;  // first warning at 8MB

    static void* lua_alloc(void* ud, void* ptr, size_t osize, size_t nsize);
    void setup_lua_paths();
};

} // namespace skynet
