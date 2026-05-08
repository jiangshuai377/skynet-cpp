#include "lua_actor.h"
#include "lua_seri.h"
#include "platform.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

using namespace skynet;

// ============================================================================
// Helper: retrieve the LuaActor* from registry
// ============================================================================

static LuaActor* get_actor(lua_State* L) {
    if (lua_type(L, lua_upvalueindex(1)) == LUA_TLIGHTUSERDATA) {
        return static_cast<LuaActor*>(
            lua_touserdata(L, lua_upvalueindex(1)));
    }

    lua_getfield(L, LUA_REGISTRYINDEX, "skynet_actor");
    auto* actor = static_cast<LuaActor*>(lua_touserdata(L, -1));
    lua_pop(L, 1);
    return actor;
}

// ============================================================================
// skynet.core.send(dest, source, type, session, msg, sz)
//
// dest: integer (handle)
// source: integer (0 means self)
// type: integer (PTYPE_*)
// session: integer (0 or specific session, nil = alloc)
// msg: lightuserdata or string
// sz: integer (if msg is lightuserdata)
// ============================================================================

static int lsend(lua_State* L) {
    auto* actor = get_actor(L);
    if (!actor) return luaL_error(L, "no skynet actor context");

    uint32_t dest = static_cast<uint32_t>(luaL_checkinteger(L, 1));
    // arg 2: source (unused, we always use self)
    int type = static_cast<int>(luaL_checkinteger(L, 3));

    int session = 0;
    if (lua_isnil(L, 4)) {
        session = actor->gen_session();
    } else {
        session = static_cast<int>(luaL_checkinteger(L, 4));
    }

    // Get message data
    MessagePayload data;
    int mtype = lua_type(L, 5);
    if (mtype == LUA_TSTRING) {
        size_t len = 0;
        const char* str = lua_tolstring(L, 5, &len);
        data = std::string(str, len);
    } else if (mtype == LUA_TLIGHTUSERDATA) {
        void* ptr = lua_touserdata(L, 5);
        size_t sz = static_cast<size_t>(luaL_checkinteger(L, 6));
        // Transfer ownership: receiver frees
        data = SeriData{ptr, sz};
    } else if (mtype == LUA_TNIL || mtype == LUA_TNONE) {
        data = std::string();
    } else {
        return luaL_error(L, "invalid message type");
    }

    actor->system().send(actor->handle(), dest, type, session,
                         std::move(data));

    lua_pushinteger(L, session);
    return 1;
}

// ============================================================================
// skynet.core.callback(func)
//
// Register the Lua function that receives all messages.
// Stored in registry as "skynet_callback".
// ============================================================================

static int lcallback(lua_State* L) {
    auto* actor = get_actor(L);
    if (!actor) return luaL_error(L, "no skynet actor context");
    luaL_checktype(L, 1, LUA_TFUNCTION);
    lua_pushvalue(L, 1);
    actor->set_callback_ref(luaL_ref(L, LUA_REGISTRYINDEX));
    return 0;
}

// ============================================================================
// skynet.core.genid() -> session_id
// ============================================================================

static int lgenid(lua_State* L) {
    auto* actor = get_actor(L);
    if (!actor) return luaL_error(L, "no skynet actor context");
    int session = actor->gen_session();
    lua_pushinteger(L, session);
    return 1;
}

// ============================================================================
// skynet.core.self() -> handle
// ============================================================================

static int lself(lua_State* L) {
    auto* actor = get_actor(L);
    if (!actor) return luaL_error(L, "no skynet actor context");
    lua_pushinteger(L, actor->handle());
    return 1;
}

// ============================================================================
// skynet.core.now() -> centiseconds since start
// ============================================================================

static auto start_time = std::chrono::steady_clock::now();

static int lnow(lua_State* L) {
    auto now = std::chrono::steady_clock::now();
    auto cs = std::chrono::duration_cast<std::chrono::milliseconds>(
                  now - start_time).count() / 10;
    lua_pushinteger(L, static_cast<lua_Integer>(cs));
    return 1;
}

// ============================================================================
// skynet.core.error(text)
// ============================================================================

static int lerror(lua_State* L) {
    auto* actor = get_actor(L);
    if (!actor) return luaL_error(L, "no skynet actor context");

    size_t len = 0;
    const char* str = luaL_checklstring(L, 1, &len);
    actor->system().error(actor->handle(), "%.*s",
                          static_cast<int>(len), str);
    return 0;
}

// ============================================================================
// skynet.core.reg(name) -> ":handle_hex"
// Register a name for the current service, returns handle as hex string.
// ============================================================================

static int lreg(lua_State* L) {
    auto* actor = get_actor(L);
    if (!actor) return luaL_error(L, "no skynet actor context");

    if (lua_gettop(L) >= 1 && !lua_isnil(L, 1)) {
        const char* name = luaL_checkstring(L, 1);
        actor->system().register_name(std::string(name), actor->handle());
    }
    char buf[16];
    std::snprintf(buf, sizeof(buf), ":%08x", actor->handle());
    lua_pushstring(L, buf);
    return 1;
}

// ============================================================================
// skynet.core.nameservice(name, handle) -> nil
// Register a name for an arbitrary handle.
// ============================================================================

static int lnameservice(lua_State* L) {
    auto* actor = get_actor(L);
    if (!actor) return luaL_error(L, "no skynet actor context");

    const char* name = luaL_checkstring(L, 1);
    uint32_t handle = static_cast<uint32_t>(luaL_checkinteger(L, 2));
    actor->system().register_name(std::string(name), handle);
    return 0;
}

// ============================================================================
// skynet.core.query(name) -> handle (integer) or nil
// ============================================================================

static int lquery(lua_State* L) {
    auto* actor = get_actor(L);
    if (!actor) return luaL_error(L, "no skynet actor context");

    const char* name = luaL_checkstring(L, 1);
    uint32_t h = actor->system().find_name(std::string(name));
    if (h == 0) { lua_pushnil(L); return 1; }
    lua_pushinteger(L, h);
    return 1;
}

// ============================================================================
// skynet.core.exit() -- kill current service
// ============================================================================

static int lexit(lua_State* L) {
    auto* actor = get_actor(L);
    if (!actor) return luaL_error(L, "no skynet actor context");
    actor->system().kill(actor->handle());
    return 0;
}

// ============================================================================
// skynet.core.kill(handle) -- kill a service by integer handle
// ============================================================================

static int lkill(lua_State* L) {
    auto* actor = get_actor(L);
    if (!actor) return luaL_error(L, "no skynet actor context");

    uint32_t h = static_cast<uint32_t>(luaL_checkinteger(L, 1));
    if (h != 0) actor->system().kill(h);
    return 0;
}

// ============================================================================
// skynet.core.shutdown() -- stop the whole actor system
// ============================================================================

static int lshutdown(lua_State* L) {
    auto* actor = get_actor(L);
    if (!actor) return luaL_error(L, "no skynet actor context");
    actor->system().shutdown();
    return 0;
}

// ============================================================================
// skynet.core environment lookup -> value or nil
// ============================================================================

static int lcore_env(lua_State* L) {
    const char* name = luaL_checkstring(L, 1);
    std::string value = platform::getenv_string(name);
    if (!value.empty()) {
        lua_pushlstring(L, value.data(), value.size());
    } else {
        lua_pushnil(L);
    }
    return 1;
}

// ============================================================================
// Global Lua path configuration
// ============================================================================

static int lgetcwd(lua_State* L) {
    std::string cwd = platform::current_path();
    lua_pushlstring(L, cwd.data(), cwd.size());
    return 1;
}

static int lsetpathbase(lua_State* L) {
    auto* actor = get_actor(L);
    if (!actor) return luaL_error(L, "no skynet actor context");
    actor->system().set_lua_path_base(luaL_checkstring(L, 1));
    return 0;
}

static int lgetpathbase(lua_State* L) {
    auto* actor = get_actor(L);
    if (!actor) return luaL_error(L, "no skynet actor context");
    std::string path_base = actor->system().lua_path_base();
    lua_pushlstring(L, path_base.data(), path_base.size());
    return 1;
}

static int lappendpath(lua_State* L) {
    auto* actor = get_actor(L);
    if (!actor) return luaL_error(L, "no skynet actor context");
    actor->system().append_lua_path(luaL_checkstring(L, 1));
    return 0;
}

static int lprependpath(lua_State* L) {
    auto* actor = get_actor(L);
    if (!actor) return luaL_error(L, "no skynet actor context");
    actor->system().prepend_lua_path(luaL_checkstring(L, 1));
    return 0;
}

static int lappendcpath(lua_State* L) {
    auto* actor = get_actor(L);
    if (!actor) return luaL_error(L, "no skynet actor context");
    actor->system().append_lua_cpath(luaL_checkstring(L, 1));
    return 0;
}

static int lappendservicepath(lua_State* L) {
    auto* actor = get_actor(L);
    if (!actor) return luaL_error(L, "no skynet actor context");
    actor->system().append_lua_service_path(luaL_checkstring(L, 1));
    return 0;
}

static int lgetpath(lua_State* L) {
    auto* actor = get_actor(L);
    if (!actor) return luaL_error(L, "no skynet actor context");
    auto paths = actor->system().lua_path_config();
    lua_createtable(L, 0, 4);
    lua_pushlstring(L, paths.path_base.data(), paths.path_base.size());
    lua_setfield(L, -2, "path_base");
    lua_pushlstring(L, paths.path.data(), paths.path.size());
    lua_setfield(L, -2, "path");
    lua_pushlstring(L, paths.cpath.data(), paths.cpath.size());
    lua_setfield(L, -2, "cpath");
    lua_pushlstring(L, paths.service_path.data(), paths.service_path.size());
    lua_setfield(L, -2, "service_path");
    return 1;
}

// ============================================================================
// skynet.core.writefile(path, data [, append]) -> true or nil, error
// ============================================================================

static int lwritefile(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    size_t len = 0;
    const char* data = luaL_checklstring(L, 2, &len);
    bool append = lua_toboolean(L, 3) != 0;

    std::string error;
    if (!platform::write_file(path, std::string_view(data, len), append, &error)) {
        lua_pushnil(L);
        lua_pushlstring(L, error.data(), error.size());
        return 2;
    }
    lua_pushboolean(L, 1);
    return 1;
}

// ============================================================================
// skynet.core.readfile(path) -> data or nil, error
// ============================================================================

static int lreadfile(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);

    std::string data;
    std::string error;
    if (!platform::read_file(path, &data, &error)) {
        lua_pushnil(L);
        lua_pushlstring(L, error.data(), error.size());
        return 2;
    }
    lua_pushlstring(L, data.data(), data.size());
    return 1;
}

// ============================================================================
// skynet.core.timeout(ti [, session]) -> session  (ti in centiseconds)
// ============================================================================

static int ltimeout(lua_State* L) {
    auto* actor = get_actor(L);
    if (!actor) return luaL_error(L, "no skynet actor context");

    lua_Integer ti = luaL_checkinteger(L, 1);
    // ti is in centiseconds, convert to milliseconds avoiding overflow
    auto ms = std::chrono::milliseconds(
        static_cast<int64_t>(ti) * 10);
    int session = 0;
    if (lua_gettop(L) >= 2 && !lua_isnil(L, 2)) {
        session = static_cast<int>(luaL_checkinteger(L, 2));
        actor->system().timeout(actor->handle(), session, ms);
    } else {
        session = actor->timeout(ms);
    }
    lua_pushinteger(L, session);
    return 1;
}

// ============================================================================
// skynet.core.tostring(msg, sz) -> string
// ============================================================================

static int ltostring(lua_State* L) {
    int t = lua_type(L, 1);
    if (t == LUA_TSTRING) {
        lua_settop(L, 1);
        return 1;
    }
    if (t == LUA_TLIGHTUSERDATA) {
        void* ptr = lua_touserdata(L, 1);
        size_t sz = static_cast<size_t>(luaL_checkinteger(L, 2));
        lua_pushlstring(L, static_cast<const char*>(ptr), sz);
        return 1;
    }
    return luaL_error(L, "skynet.tostring: invalid type %s",
                      lua_typename(L, t));
}

// ============================================================================
// skynet.core.trash(msg, sz) -- free a lightuserdata buffer
// ============================================================================

static int ltrash(lua_State* L) {
    int t = lua_type(L, 1);
    if (t == LUA_TLIGHTUSERDATA) {
        void* ptr = lua_touserdata(L, 1);
        std::free(ptr);
    }
    // if string, nothing to free
    return 0;
}

// ============================================================================
// skynet.core.redirect(dest, source, type, session, msg, sz)
// Send with explicit source
// ============================================================================

static int lredirect(lua_State* L) {
    auto* actor = get_actor(L);
    if (!actor) return luaL_error(L, "no skynet actor context");

    uint32_t dest = static_cast<uint32_t>(luaL_checkinteger(L, 1));
    uint32_t source = static_cast<uint32_t>(luaL_checkinteger(L, 2));
    int type = static_cast<int>(luaL_checkinteger(L, 3));
    int session = static_cast<int>(luaL_checkinteger(L, 4));

    MessagePayload data;
    int mtype = lua_type(L, 5);
    if (mtype == LUA_TSTRING) {
        size_t len = 0;
        const char* str = lua_tolstring(L, 5, &len);
        data = std::string(str, len);
    } else if (mtype == LUA_TLIGHTUSERDATA) {
        void* ptr = lua_touserdata(L, 5);
        size_t sz = static_cast<size_t>(luaL_checkinteger(L, 6));
        data = SeriData{ptr, sz};
    } else {
        data = std::string();
    }

    actor->system().send(source, dest, type, session, std::move(data));
    return 0;
}

// ============================================================================
// skynet.core.harbor(addr) -> harbor_id
// We don't have harbor support, always return 0
// ============================================================================

static int lharbor(lua_State* L) {
    lua_pushinteger(L, 0);
    lua_pushinteger(L, 0);
    return 2;
}

// ============================================================================
// skynet.core.newservice(script_name) -> handle
//
// Spawn a new LuaActor running the given script.
// Returns the integer handle of the new actor.
// ============================================================================

static int lnewservice(lua_State* L) {
    auto* actor = get_actor(L);
    if (!actor) return luaL_error(L, "no skynet actor context");

    const char* name = luaL_checkstring(L, 1);

    // Build param. Plain service names are resolved by loader.lua through
    // LUA_SERVICE so runtime services, tests, and examples can live separately.
    std::string param(name);

    // Append extra arguments separated by spaces
    int n = lua_gettop(L);
    for (int i = 2; i <= n; ++i) {
        param += " ";
        const char* arg = luaL_checkstring(L, i);
        param += arg;
    }

    uint32_t handle = actor->system().spawn<LuaActor>(param);
    if (handle == 0) {
        return luaL_error(L, "failed to spawn service: %s", name);
    }

    lua_pushinteger(L, handle);
    return 1;
}

// ============================================================================
// Module registration: luaopen_skynet_core
// ============================================================================
// skynet.core.mem() -> current Lua VM memory in KB
// ============================================================================

static int lmem(lua_State* L) {
    int kb = lua_gc(L, LUA_GCCOUNT, 0);
    int bytes = lua_gc(L, LUA_GCCOUNTB, 0);
    lua_pushnumber(L, kb + bytes / 1024.0);
    return 1;
}

// ============================================================================
// skynet.core.gc() -> trigger full GC, returns memory in KB after GC
// ============================================================================

static int lgc(lua_State* L) {
    lua_gc(L, LUA_GCCOLLECT, 0);
    int kb = lua_gc(L, LUA_GCCOUNT, 0);
    int bytes = lua_gc(L, LUA_GCCOUNTB, 0);
    lua_pushnumber(L, kb + bytes / 1024.0);
    return 1;
}

// ============================================================================
// skynet.core.memlimit(bytes) -> set memory limit for current VM
// Pass 0 to remove the limit. Returns previous limit.
// ============================================================================

static int lmemlimit(lua_State* L) {
    auto* actor = get_actor(L);
    if (!actor) return luaL_error(L, "no skynet actor context");

    auto* la = static_cast<LuaActor*>(actor);
    size_t old_limit = la->get_mem_limit();

    if (lua_gettop(L) >= 1) {
        size_t new_limit = static_cast<size_t>(luaL_checkinteger(L, 1));
        la->set_mem_limit(new_limit);
    }

    lua_pushinteger(L, static_cast<lua_Integer>(old_limit));
    return 1;
}

// ============================================================================
// skynet.core.memused() -> current VM memory usage in bytes (from allocator)
// ============================================================================

static int lmemused(lua_State* L) {
    auto* actor = get_actor(L);
    if (!actor) return luaL_error(L, "no skynet actor context");

    auto* la = static_cast<LuaActor*>(actor);
    lua_pushinteger(L, static_cast<lua_Integer>(la->get_mem_used()));
    return 1;
}

// ============================================================================
// skynet.core.starttime() -> process start time (centiseconds since epoch)
// ============================================================================

static int lstarttime(lua_State* L) {
    // Return start_time as seconds since epoch
    auto epoch_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        start_time.time_since_epoch()).count();
    lua_pushinteger(L, static_cast<lua_Integer>(epoch_ms / 10));
    return 1;
}

// ============================================================================
// skynet.core.systemstat() -> table
// ============================================================================

static int lsystemstat(lua_State* L) {
    auto* actor = get_actor(L);
    if (!actor) return luaL_error(L, "no skynet actor context");

    auto stats = actor->system().stats();
    lua_createtable(L, 0, 9);

    lua_pushboolean(L, stats.running);
    lua_setfield(L, -2, "running");
    lua_pushinteger(L, stats.worker_count);
    lua_setfield(L, -2, "worker_count");
    lua_pushinteger(L, static_cast<lua_Integer>(stats.actor_count));
    lua_setfield(L, -2, "actor_count");
    lua_pushinteger(L, stats.global_queue_count);
    lua_setfield(L, -2, "global_queue_count");
    lua_pushinteger(L, stats.sleeping_workers);
    lua_setfield(L, -2, "sleeping_workers");
    lua_pushinteger(L, static_cast<lua_Integer>(stats.global_queue_epoch));
    lua_setfield(L, -2, "global_queue_epoch");
    lua_pushinteger(L, static_cast<lua_Integer>(stats.queued_messages));
    lua_setfield(L, -2, "queued_messages");
    lua_pushinteger(L, static_cast<lua_Integer>(stats.active_queues));
    lua_setfield(L, -2, "active_queues");
    lua_pushinteger(L, static_cast<lua_Integer>(stats.releasing_queues));
    lua_setfield(L, -2, "releasing_queues");
    return 1;
}

// ============================================================================
// Module registration: luaopen_skynet_core
// ============================================================================

extern "C" int luaopen_skynet_core(lua_State* L) {
    luaL_Reg funcs[] = {
        {"send",            lsend},
        {"genid",           lgenid},
        {"redirect",        lredirect},
        {"reg",             lreg},
        {"nameservice",     lnameservice},
        {"query",           lquery},
        {"exit",            lexit},
        {"kill",            lkill},
        {"shutdown",        lshutdown},
        {"getenv",          lcore_env},
        {"getcwd",          lgetcwd},
        {"setpathbase",     lsetpathbase},
        {"getpathbase",     lgetpathbase},
        {"appendpath",      lappendpath},
        {"prependpath",     lprependpath},
        {"appendcpath",     lappendcpath},
        {"appendservicepath", lappendservicepath},
        {"getpath",         lgetpath},
        {"writefile",       lwritefile},
        {"readfile",        lreadfile},
        {"timeout",         ltimeout},
        {"error",           lerror},
        {"harbor",          lharbor},
        {"callback",        lcallback},
        {"tostring",        ltostring},
        {"pack",            luaseri_pack},
        {"unpack",          luaseri_unpack},
        {"unpacktrash",     luaseri_unpacktrash},
        {"trash",           ltrash},
        {"now",             lnow},
        {"self",            lself},
        {"newservice",      lnewservice},
        {"mem",             lmem},
        {"gc",              lgc},
        {"memlimit",        lmemlimit},
        {"memused",         lmemused},
        {"starttime",       lstarttime},
        {"systemstat",      lsystemstat},
        {nullptr, nullptr}
    };

    luaL_newlibtable(L, funcs);
    lua_getfield(L, LUA_REGISTRYINDEX, "skynet_actor");
    luaL_setfuncs(L, funcs, 1);
    return 1;
}
