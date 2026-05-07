#pragma once

extern "C" {
#include <lua.h>
}

// Lua-compatible pack/unpack for inter-actor message serialization.
// Format compatible with Skynet's lua-seri.c.
//
// skynet.pack(...)        -> lightuserdata, size
// skynet.unpack(ptr, sz)  -> values...
// skynet.unpacktrash(ptr, sz) -> values... and frees lightuserdata payload

extern "C" {
    int luaseri_pack(lua_State* L);
    int luaseri_unpack(lua_State* L);
    int luaseri_unpacktrash(lua_State* L);
}
