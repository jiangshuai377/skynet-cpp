// lua_cluster.cpp — Cluster message serialization protocol
//
// Implements the skynet cluster wire protocol:
//   packrequest(addr, session, msg, sz)  → packet, new_session [, padding_table]
//   packpush(addr, session, msg, sz)     → packet, new_session [, padding_table]
//   packresponse(session, ok, msg, sz)   → packet or table
//   unpackrequest(data)                  → addr, session, msg, sz, padding, is_push
//   unpackresponse(data)                 → session, ok, data, padding
//   append(table, msg, sz) / concat(table) → msg, sz
//   isname(addr) → boolean
//   nodename()   → string

#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <cassert>
#include <string>

#include "platform.h"

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

#define TEMP_LENGTH 0x8200
#define MULTI_PART  0x8000

static void fill_uint32(uint8_t* buf, uint32_t n) {
    buf[0] = n & 0xff;
    buf[1] = (n >> 8) & 0xff;
    buf[2] = (n >> 16) & 0xff;
    buf[3] = (n >> 24) & 0xff;
}

static uint32_t unpack_uint32(const uint8_t* buf) {
    return buf[0] | (buf[1] << 8) | (buf[2] << 16) | (buf[3] << 24);
}

static void fill_header(uint8_t* buf, int sz) {
    assert(sz < 0x10000);
    buf[0] = (sz >> 8) & 0xff;
    buf[1] = sz & 0xff;
}

static int unpack_header(const uint8_t* buf) {
    return (buf[0] << 8) | buf[1];
}

// ============================================================================
// Pack request (numeric address)
// ============================================================================
static int packreq_number(lua_State* L, int session, const char* msg, uint32_t sz, int is_push) {
    uint32_t addr = static_cast<uint32_t>(lua_tointeger(L, 1));
    uint8_t buf[TEMP_LENGTH];
    if (sz < MULTI_PART) {
        fill_header(buf, sz + 9);
        buf[2] = 0;
        fill_uint32(buf + 3, addr);
        fill_uint32(buf + 7, is_push ? 0 : static_cast<uint32_t>(session));
        memcpy(buf + 11, msg, sz);
        lua_pushlstring(L, reinterpret_cast<const char*>(buf), sz + 11);
        return 0;
    } else {
        int part = (sz - 1) / MULTI_PART + 1;
        fill_header(buf, 13);
        buf[2] = is_push ? 0x41 : 1;
        fill_uint32(buf + 3, addr);
        fill_uint32(buf + 7, static_cast<uint32_t>(session));
        fill_uint32(buf + 11, sz);
        lua_pushlstring(L, reinterpret_cast<const char*>(buf), 15);
        return part;
    }
}

// ============================================================================
// Pack request (string address)
// ============================================================================
static int packreq_string(lua_State* L, int session, const char* msg, uint32_t sz, int is_push) {
    size_t namelen = 0;
    const char* name = lua_tolstring(L, 1, &namelen);
    if (!name || namelen < 1 || namelen > 255) {
        return luaL_error(L, "name length must be 1-255");
    }
    uint8_t buf[TEMP_LENGTH];
    if (sz < MULTI_PART) {
        fill_header(buf, static_cast<int>(sz + 6 + namelen));
        buf[2] = 0x80;
        buf[3] = static_cast<uint8_t>(namelen);
        memcpy(buf + 4, name, namelen);
        fill_uint32(buf + 4 + namelen, is_push ? 0 : static_cast<uint32_t>(session));
        memcpy(buf + 8 + namelen, msg, sz);
        lua_pushlstring(L, reinterpret_cast<const char*>(buf), sz + 8 + namelen);
        return 0;
    } else {
        int part = (sz - 1) / MULTI_PART + 1;
        fill_header(buf, static_cast<int>(10 + namelen));
        buf[2] = is_push ? 0xc1 : 0x81;
        buf[3] = static_cast<uint8_t>(namelen);
        memcpy(buf + 4, name, namelen);
        fill_uint32(buf + 4 + namelen, static_cast<uint32_t>(session));
        fill_uint32(buf + 8 + namelen, sz);
        lua_pushlstring(L, reinterpret_cast<const char*>(buf), 12 + namelen);
        return part;
    }
}

// ============================================================================
// Pack multi-part chunks into a table
// ============================================================================
static void packreq_multi(lua_State* L, int session, const char* msg, uint32_t sz) {
    int part = (sz - 1) / MULTI_PART + 1;
    uint8_t buf[TEMP_LENGTH];
    const char* ptr = msg;
    for (int i = 0; i < part; ++i) {
        uint32_t s;
        if (sz > MULTI_PART) {
            s = MULTI_PART;
            buf[2] = 2;  // more parts
        } else {
            s = sz;
            buf[2] = 3;  // last part
        }
        fill_header(buf, s + 5);
        fill_uint32(buf + 3, static_cast<uint32_t>(session));
        memcpy(buf + 7, ptr, s);
        lua_pushlstring(L, reinterpret_cast<const char*>(buf), s + 7);
        lua_rawseti(L, -2, i + 1);
        sz -= s;
        ptr += s;
    }
}

// ============================================================================
// packrequest / packpush common
// ============================================================================
static int packrequest(lua_State* L, int is_push) {
    // Args: addr(1), session(2), msg(3), sz(4)
    const char* msg = nullptr;
    uint32_t sz = 0;
    int msg_type = lua_type(L, 3);
    if (msg_type == LUA_TLIGHTUSERDATA) {
        msg = static_cast<const char*>(lua_touserdata(L, 3));
        sz = static_cast<uint32_t>(luaL_checkinteger(L, 4));
    } else if (msg_type == LUA_TSTRING) {
        size_t ssz = 0;
        msg = lua_tolstring(L, 3, &ssz);
        sz = static_cast<uint32_t>(ssz);
    } else if (msg_type == LUA_TNIL || msg_type == LUA_TNONE) {
        msg = "";
        sz = 0;
    } else {
        return luaL_error(L, "invalid message type for packrequest");
    }

    int session = static_cast<int>(luaL_checkinteger(L, 2));
    if (session <= 0) {
        return luaL_error(L, "invalid session %d", session);
    }

    int addr_type = lua_type(L, 1);
    int multipak;
    if (addr_type == LUA_TNUMBER) {
        multipak = packreq_number(L, session, msg, sz, is_push);
    } else {
        multipak = packreq_string(L, session, msg, sz, is_push);
    }

    uint32_t new_session = static_cast<uint32_t>(session) + 1;
    if (new_session > INT32_MAX) {
        new_session = 1;
    }
    lua_pushinteger(L, new_session);

    if (multipak) {
        lua_createtable(L, multipak, 0);
        packreq_multi(L, session, msg, sz);
        // Free lightuserdata if that's what we got
        if (msg_type == LUA_TLIGHTUSERDATA) {
            std::free(const_cast<char*>(msg));
        }
        return 3;  // packet, new_session, padding_table
    } else {
        if (msg_type == LUA_TLIGHTUSERDATA) {
            std::free(const_cast<char*>(msg));
        }
        return 2;  // packet, new_session
    }
}

static int lpackrequest(lua_State* L) {
    return packrequest(L, 0);
}

static int lpackpush(lua_State* L) {
    return packrequest(L, 1);
}

// ============================================================================
// unpackrequest — unpack an incoming request packet (without 2-byte header)
// ============================================================================
static int unpackreq_number(lua_State* L, const uint8_t* buf, int sz) {
    if (sz < 9) return luaL_error(L, "Invalid cluster message (size=%d)", sz);
    uint32_t address = unpack_uint32(buf + 1);
    uint32_t session = unpack_uint32(buf + 5);
    lua_pushinteger(L, address);
    lua_pushinteger(L, session);
    lua_pushlstring(L, reinterpret_cast<const char*>(buf + 9), sz - 9);
    lua_pushinteger(L, sz - 9);
    if (session == 0) {
        lua_pushnil(L);        // padding
        lua_pushboolean(L, 1); // is_push
        return 6;
    }
    return 4;
}

static int unpackmreq_number(lua_State* L, const uint8_t* buf, int sz, int is_push) {
    if (sz != 13) return luaL_error(L, "Invalid cluster multi-req (size=%d, must be 13)", sz);
    uint32_t address = unpack_uint32(buf + 1);
    uint32_t session = unpack_uint32(buf + 5);
    uint32_t size = unpack_uint32(buf + 9);
    lua_pushinteger(L, address);
    lua_pushinteger(L, session);
    lua_pushnil(L);              // msg
    lua_pushinteger(L, size);    // total size
    lua_pushboolean(L, 1);      // padding
    lua_pushboolean(L, is_push);
    return 6;
}

static int unpackmreq_part(lua_State* L, const uint8_t* buf, int sz) {
    if (sz < 5) return luaL_error(L, "Invalid cluster multi part message");
    int padding = (buf[0] == 2);
    uint32_t session = unpack_uint32(buf + 1);
    lua_pushboolean(L, 0);  // no address (continuation)
    lua_pushinteger(L, session);
    lua_pushlstring(L, reinterpret_cast<const char*>(buf + 5), sz - 5);
    lua_pushinteger(L, sz - 5);
    lua_pushboolean(L, padding);
    return 5;
}

static int unpackreq_string(lua_State* L, const uint8_t* buf, int sz) {
    if (sz < 2) return luaL_error(L, "Invalid cluster message (size=%d)", sz);
    size_t namesz = buf[1];
    if (sz < static_cast<int>(namesz + 6))
        return luaL_error(L, "Invalid cluster message (size=%d)", sz);
    lua_pushlstring(L, reinterpret_cast<const char*>(buf + 2), namesz);
    uint32_t session = unpack_uint32(buf + namesz + 2);
    lua_pushinteger(L, session);
    int data_offset = static_cast<int>(namesz + 6);
    lua_pushlstring(L, reinterpret_cast<const char*>(buf + data_offset), sz - data_offset);
    lua_pushinteger(L, sz - data_offset);
    if (session == 0) {
        lua_pushnil(L);        // padding
        lua_pushboolean(L, 1); // is_push
        return 6;
    }
    return 4;
}

static int unpackmreq_string(lua_State* L, const uint8_t* buf, int sz, int is_push) {
    if (sz < 2) return luaL_error(L, "Invalid cluster message (size=%d)", sz);
    size_t namesz = buf[1];
    if (sz < static_cast<int>(namesz + 10))
        return luaL_error(L, "Invalid cluster message (size=%d)", sz);
    lua_pushlstring(L, reinterpret_cast<const char*>(buf + 2), namesz);
    uint32_t session = unpack_uint32(buf + namesz + 2);
    uint32_t size = unpack_uint32(buf + namesz + 6);
    lua_pushinteger(L, session);
    lua_pushnil(L);
    lua_pushinteger(L, size);
    lua_pushboolean(L, 1);      // padding
    lua_pushboolean(L, is_push);
    return 6;
}

static int lunpackrequest(lua_State* L) {
    size_t ssz;
    const char* msg = luaL_checklstring(L, 1, &ssz);
    int sz = static_cast<int>(ssz);
    if (sz == 0) return luaL_error(L, "Invalid req package: size == 0");

    switch (msg[0]) {
    case 0:     return unpackreq_number(L, reinterpret_cast<const uint8_t*>(msg), sz);
    case 1:     return unpackmreq_number(L, reinterpret_cast<const uint8_t*>(msg), sz, 0);
    case 0x41:  return unpackmreq_number(L, reinterpret_cast<const uint8_t*>(msg), sz, 1);
    case 2:
    case 3:     return unpackmreq_part(L, reinterpret_cast<const uint8_t*>(msg), sz);
    case '\x80':  return unpackreq_string(L, reinterpret_cast<const uint8_t*>(msg), sz);
    case '\x81':  return unpackmreq_string(L, reinterpret_cast<const uint8_t*>(msg), sz, 0);
    case '\xc1':  return unpackmreq_string(L, reinterpret_cast<const uint8_t*>(msg), sz, 1);
    default:
        return luaL_error(L, "Invalid req package type %d", static_cast<int>(msg[0]));
    }
}

// ============================================================================
// packresponse(session, ok, msg [, sz])
// ============================================================================
static int lpackresponse(lua_State* L) {
    uint32_t session = static_cast<uint32_t>(luaL_checkinteger(L, 1));
    int ok = lua_toboolean(L, 2);

    const char* msg = nullptr;
    size_t sz = 0;
    bool msg_is_lightuserdata = false;
    if (lua_type(L, 3) == LUA_TSTRING) {
        msg = lua_tolstring(L, 3, &sz);
    } else if (lua_type(L, 3) == LUA_TLIGHTUSERDATA) {
        msg = static_cast<const char*>(lua_touserdata(L, 3));
        sz = static_cast<size_t>(luaL_checkinteger(L, 4));
        msg_is_lightuserdata = true;
    } else if (lua_isnil(L, 3)) {
        msg = "";
        sz = 0;
    } else {
        return luaL_error(L, "invalid msg type for packresponse");
    }

    if (!ok) {
        if (sz > MULTI_PART) sz = MULTI_PART;  // truncate error
    } else {
        if (sz > MULTI_PART) {
            // Multi-part response
            int part = (sz - 1) / MULTI_PART + 1;
            lua_createtable(L, part + 1, 0);
            uint8_t buf[TEMP_LENGTH];

            // Multi-part begin header
            fill_header(buf, 9);
            fill_uint32(buf + 2, session);
            buf[6] = 2;  // multi begin
            fill_uint32(buf + 7, static_cast<uint32_t>(sz));
            lua_pushlstring(L, reinterpret_cast<const char*>(buf), 11);
            lua_rawseti(L, -2, 1);

            const char* ptr = msg;
            size_t remaining = sz;
            for (int i = 0; i < part; ++i) {
                size_t s;
                if (remaining > MULTI_PART) {
                    s = MULTI_PART;
                    buf[6] = 3;  // multi part
                } else {
                    s = remaining;
                    buf[6] = 4;  // multi end
                }
                fill_header(buf, static_cast<int>(s + 5));
                fill_uint32(buf + 2, session);
                memcpy(buf + 7, ptr, s);
                lua_pushlstring(L, reinterpret_cast<const char*>(buf), s + 7);
                lua_rawseti(L, -2, i + 2);
                remaining -= s;
                ptr += s;
            }
            if (msg_is_lightuserdata) {
                std::free(const_cast<char*>(msg));
            }
            return 1;
        }
    }

    // Single-part response
    uint8_t buf[TEMP_LENGTH];
    fill_header(buf, static_cast<int>(sz + 5));
    fill_uint32(buf + 2, session);
    buf[6] = ok ? 1 : 0;
    memcpy(buf + 7, msg, sz);
    lua_pushlstring(L, reinterpret_cast<const char*>(buf), sz + 7);
    if (msg_is_lightuserdata) {
        std::free(const_cast<char*>(msg));
    }
    return 1;
}

// ============================================================================
// unpackresponse(data) → session, ok, data [, padding]
// ============================================================================
static int lunpackresponse(lua_State* L) {
    size_t sz;
    const char* buf = luaL_checklstring(L, 1, &sz);
    if (sz < 5) return 0;
    uint32_t session = unpack_uint32(reinterpret_cast<const uint8_t*>(buf));
    lua_pushinteger(L, session);

    switch (buf[4]) {
    case 0:  // error
        lua_pushboolean(L, 0);
        lua_pushlstring(L, buf + 5, sz - 5);
        return 3;
    case 1:  // ok
    case 4:  // multi end
        lua_pushboolean(L, 1);
        lua_pushlstring(L, buf + 5, sz - 5);
        return 3;
    case 2:  // multi begin
        if (sz != 9) return 0;
        {
            uint32_t total = unpack_uint32(reinterpret_cast<const uint8_t*>(buf + 5));
            lua_pushboolean(L, 1);
            lua_pushinteger(L, total);
            lua_pushboolean(L, 1);  // padding
        }
        return 4;
    case 3:  // multi part
        lua_pushboolean(L, 1);
        lua_pushlstring(L, buf + 5, sz - 5);
        lua_pushboolean(L, 1);  // padding
        return 4;
    default:
        return 0;
    }
}

// ============================================================================
// append(table, msg, sz) — append string data to table
// ============================================================================
static int lappend(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    int n = static_cast<int>(lua_rawlen(L, 1));

    if (lua_isnil(L, 2)) {
        lua_settop(L, 3);
        lua_seti(L, 1, n + 1);
        return 0;
    }

    int t = lua_type(L, 2);
    if (t == LUA_TSTRING) {
        lua_pushvalue(L, 2);
    } else if (t == LUA_TLIGHTUSERDATA) {
        void* buffer = lua_touserdata(L, 2);
        int sz2 = static_cast<int>(luaL_checkinteger(L, 3));
        lua_pushlstring(L, static_cast<const char*>(buffer), sz2);
        std::free(buffer);
    } else {
        return luaL_error(L, "invalid type for append");
    }
    lua_seti(L, 1, n + 1);
    return 0;
}

// ============================================================================
// concat(table) → string
// ============================================================================
static int lconcat(lua_State* L) {
    if (!lua_istable(L, 1)) return 0;
    if (lua_geti(L, 1, 1) != LUA_TNUMBER) return 0;
    int sz = static_cast<int>(lua_tointeger(L, -1));
    lua_pop(L, 1);

    // Collect all string parts
    luaL_Buffer b;
    luaL_buffinit(L, &b);
    int idx = 2;
    int total = 0;
    while (lua_geti(L, 1, idx) == LUA_TSTRING) {
        size_t s;
        const char* str = lua_tolstring(L, -1, &s);
        luaL_addlstring(&b, str, s);
        total += static_cast<int>(s);
        lua_pop(L, 1);
        ++idx;
    }
    lua_pop(L, 1);

    if (total != sz) return 0;
    luaL_pushresult(&b);
    lua_pushinteger(L, sz);
    return 2;
}

// ============================================================================
// isname(addr) → boolean
// ============================================================================
static int lisname(lua_State* L) {
    const char* name = lua_tostring(L, 1);
    if (name && name[0] == '@') {
        lua_pushboolean(L, 1);
        return 1;
    }
    return 0;
}

// ============================================================================
// nodename() → string (hostname + pid)
// ============================================================================
static int lnodename(lua_State* L) {
    std::string name = skynet::platform::node_name();
    lua_pushlstring(L, name.data(), name.size());
    return 1;
}

// ============================================================================
// header(data) — read 2-byte big-endian size header
// ============================================================================
static int lheader(lua_State* L) {
    size_t sz;
    const char* buf = luaL_checklstring(L, 1, &sz);
    if (sz < 2) return luaL_error(L, "header needs at least 2 bytes");
    int header = unpack_header(reinterpret_cast<const uint8_t*>(buf));
    lua_pushinteger(L, header);
    return 1;
}

// ============================================================================
// Module registration
// ============================================================================
extern "C" int luaopen_cluster_core(lua_State* L) {
    luaL_Reg funcs[] = {
        {"packrequest",    lpackrequest},
        {"packpush",       lpackpush},
        {"packresponse",   lpackresponse},
        {"unpackrequest",  lunpackrequest},
        {"unpackresponse", lunpackresponse},
        {"append",         lappend},
        {"concat",         lconcat},
        {"isname",         lisname},
        {"nodename",       lnodename},
        {"header",         lheader},
        {nullptr, nullptr}
    };
    luaL_newlib(L, funcs);
    return 1;
}
