// lua_profile.cpp — skynet.profile module for skynet-cpp
//
// Provides CPU-time profiling for Lua coroutines by hooking
// coroutine.resume and coroutine.wrap.
//
// Equivalent to the profile portion of service_snlua.c in original skynet.

#include <chrono>

#include "platform.h"

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

// ============================================================================
// High-resolution timer for profiling
// ============================================================================

static double get_time() {
    return skynet::platform::profile_time_seconds();
}

static inline double diff_time(double start) {
    double now = get_time();
    if (now < start) {
        return now + 0x10000 - start;
    }
    return now - start;
}

// ============================================================================
// Upvalue layout:
//   upvalue[1] = table: thread -> start_time (weak kv)
//   upvalue[2] = table: thread -> total_time (weak kv)
// ============================================================================

// Check if profiling is enabled for the coroutine at stack index co_index.
// If enabled, writes start_time into *out and returns 1.
static int timing_enable(lua_State* L, int co_index, lua_Number* out) {
    lua_pushvalue(L, co_index);
    lua_rawget(L, lua_upvalueindex(1));
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return 0;
    }
    *out = lua_tonumber(L, -1);
    lua_pop(L, 1);
    return 1;
}

// Get accumulated total time for the coroutine.
static double timing_total(lua_State* L, int co_index) {
    lua_pushvalue(L, co_index);
    lua_rawget(L, lua_upvalueindex(2));
    double total = lua_tonumber(L, -1);
    lua_pop(L, 1);
    return total;
}

// ============================================================================
// coroutine.resume replacement with timing
// ============================================================================

static int auxresume(lua_State* L, lua_State* co, int narg) {
    int status, nres;
    if (!lua_checkstack(co, narg)) {
        lua_pushliteral(L, "too many arguments to resume");
        return -1;
    }
    lua_xmove(L, co, narg);
    status = lua_resume(co, L, narg, &nres);
    if (status == LUA_OK || status == LUA_YIELD) {
        if (!lua_checkstack(L, nres + 1)) {
            lua_pop(co, nres);
            lua_pushliteral(L, "too many results to resume");
            return -1;
        }
        lua_xmove(co, L, nres);
        return nres;
    } else {
        lua_xmove(co, L, 1);  // move error message
        return -1;
    }
}

static int timing_resume(lua_State* L, int co_index, int n) {
    lua_State* co = lua_tothread(L, co_index);
    lua_Number start_time = 0;

    if (timing_enable(L, co_index, &start_time)) {
        start_time = get_time();
        lua_pushvalue(L, co_index);
        lua_pushnumber(L, start_time);
        lua_rawset(L, lua_upvalueindex(1));  // update start time
    }

    int r = auxresume(L, co, n);

    if (timing_enable(L, co_index, &start_time)) {
        double total = timing_total(L, co_index);
        double diff = diff_time(start_time);
        total += diff;
        lua_pushvalue(L, co_index);
        lua_pushnumber(L, total);
        lua_rawset(L, lua_upvalueindex(2));  // update total time
    }

    return r;
}

// profile.resume(co, ...) — resume with timing
static int luaB_coresume(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTHREAD);
    int r = timing_resume(L, 1, lua_gettop(L) - 1);
    if (r < 0) {
        lua_pushboolean(L, 0);
        lua_insert(L, -2);
        return 2;  // return false + error
    } else {
        lua_pushboolean(L, 1);
        lua_insert(L, -(r + 1));
        return r + 1;  // return true + results
    }
}

// Helper for profile.wrap
static int luaB_auxwrap(lua_State* L) {
    lua_State* co = lua_tothread(L, lua_upvalueindex(3));
    int r = timing_resume(L, lua_upvalueindex(3), lua_gettop(L));
    if (r < 0) {
        int stat = lua_status(co);
        if (stat != LUA_OK && stat != LUA_YIELD)
            lua_closethread(co, L);
        if (lua_type(L, -1) == LUA_TSTRING) {
            luaL_where(L, 1);
            lua_insert(L, -2);
            lua_concat(L, 2);
        }
        return lua_error(L);
    }
    return r;
}

static int luaB_cocreate(lua_State* L) {
    luaL_checktype(L, 1, LUA_TFUNCTION);
    lua_State* NL = lua_newthread(L);
    lua_pushvalue(L, 1);
    lua_xmove(L, NL, 1);
    return 1;
}

// profile.wrap(f) — create a wrapped coroutine with timing
static int luaB_cowrap(lua_State* L) {
    lua_pushvalue(L, lua_upvalueindex(1));  // timing table 1
    lua_pushvalue(L, lua_upvalueindex(2));  // timing table 2
    luaB_cocreate(L);                       // new thread
    lua_pushcclosure(L, luaB_auxwrap, 3);
    return 1;
}

// ============================================================================
// profile.start([co]) — begin profiling a coroutine
// ============================================================================

static int lstart(lua_State* L) {
    if (lua_gettop(L) != 0) {
        lua_settop(L, 1);
        luaL_checktype(L, 1, LUA_TTHREAD);
    } else {
        lua_pushthread(L);
    }

    lua_Number start_time = 0;
    if (timing_enable(L, 1, &start_time)) {
        return luaL_error(L, "Thread %p start profile more than once",
                          lua_topointer(L, 1));
    }

    // Reset total time to 0
    lua_pushvalue(L, 1);
    lua_pushnumber(L, 0);
    lua_rawset(L, lua_upvalueindex(2));

    // Set start time
    lua_pushvalue(L, 1);
    lua_pushnumber(L, get_time());
    lua_rawset(L, lua_upvalueindex(1));

    return 0;
}

// ============================================================================
// profile.stop([co]) -> total_cpu_time
// ============================================================================

static int lstop(lua_State* L) {
    if (lua_gettop(L) != 0) {
        lua_settop(L, 1);
        luaL_checktype(L, 1, LUA_TTHREAD);
    } else {
        lua_pushthread(L);
    }

    lua_Number start_time = 0;
    if (!timing_enable(L, 1, &start_time)) {
        return luaL_error(L, "Call profile.start() before profile.stop()");
    }

    double ti = diff_time(start_time);
    double total = timing_total(L, 1);

    // Clear start time
    lua_pushvalue(L, 1);
    lua_pushnil(L);
    lua_rawset(L, lua_upvalueindex(1));

    // Clear total time
    lua_pushvalue(L, 1);
    lua_pushnil(L);
    lua_rawset(L, lua_upvalueindex(2));

    total += ti;
    lua_pushnumber(L, total);
    return 1;
}

// ============================================================================
// Module init: luaopen_skynet_profile
//
// Returns a table with { start, stop, resume, wrap }.
// Also creates two weak tables as upvalues for timing data.
// ============================================================================

extern "C" int luaopen_skynet_profile(lua_State* L) {
    luaL_Reg funcs[] = {
        {"start",  lstart},
        {"stop",   lstop},
        {"resume", luaB_coresume},
        {"wrap",   luaB_cowrap},
        {nullptr,  nullptr},
    };

    luaL_newlibtable(L, funcs);

    // Create two upvalue tables (thread -> time), both with weak "kv" metatable
    lua_newtable(L);  // upvalue 1: start_time table
    lua_newtable(L);  // upvalue 2: total_time table

    lua_newtable(L);  // weak metatable
    lua_pushliteral(L, "kv");
    lua_setfield(L, -2, "__mode");

    lua_pushvalue(L, -1);       // dup metatable
    lua_setmetatable(L, -3);    // set meta on total_time
    lua_setmetatable(L, -3);    // set meta on start_time

    luaL_setfuncs(L, funcs, 2); // 2 upvalues

    return 1;
}
