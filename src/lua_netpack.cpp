// lua_netpack.cpp — TCP length-prefixed framing module for Lua
//
// Provides:
//   netpack.pack(data)              → framed string (2-byte big-endian length + payload)
//   netpack.unpack(data)            → offset, payload (or nil if incomplete)
//   netpack.filter(accumulated, new) → table of complete messages + remaining buffer
//   netpack.tostring(msg, sz)       → string

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

#include <cstring>
#include <string>

// ============================================================================
// netpack.pack(data) → framed string
// Prepends a 2-byte big-endian length header.
// ============================================================================

static int lpack(lua_State* L) {
    size_t len = 0;
    const char* data = luaL_checklstring(L, 1, &len);

    if (len > 0xFFFF) {
        return luaL_error(L, "netpack.pack: data too large (%d bytes, max 65535)",
                          static_cast<int>(len));
    }

    std::string frame(2 + len, '\0');
    frame[0] = static_cast<char>((len >> 8) & 0xFF);
    frame[1] = static_cast<char>(len & 0xFF);
    std::memcpy(&frame[2], data, len);

    lua_pushlstring(L, frame.data(), frame.size());
    return 1;
}

// ============================================================================
// netpack.unpack(buffer [, offset]) → next_offset, payload  or  nil
// Try to read one frame from buffer starting at offset (1-based, default 1).
// Returns next_offset (after consumed frame) + payload string, or nil if incomplete.
// ============================================================================

static int lunpack(lua_State* L) {
    size_t buf_len = 0;
    const char* buf = luaL_checklstring(L, 1, &buf_len);
    int offset = static_cast<int>(luaL_optinteger(L, 2, 1)) - 1;  // convert to 0-based

    if (offset < 0 || static_cast<size_t>(offset) >= buf_len) {
        lua_pushnil(L);
        return 1;
    }

    size_t remaining = buf_len - static_cast<size_t>(offset);

    // Need at least 2 bytes for header
    if (remaining < 2) {
        lua_pushnil(L);
        return 1;
    }

    size_t payload_len = (static_cast<unsigned char>(buf[offset]) << 8)
                       |  static_cast<unsigned char>(buf[offset + 1]);

    if (remaining < 2 + payload_len) {
        lua_pushnil(L);
        return 1;
    }

    // Return next_offset (1-based) and payload
    lua_pushinteger(L, offset + 2 + static_cast<int>(payload_len) + 1);
    lua_pushlstring(L, buf + offset + 2, payload_len);
    return 2;
}

// ============================================================================
// netpack.filter(buffer, new_data) → msgs_table, remaining_buffer
// Appends new_data to buffer, extracts all complete frames.
// Returns a table array of payload strings + the unconsumed remainder.
// ============================================================================

static int lfilter(lua_State* L) {
    size_t buf_len = 0;
    const char* buf = luaL_checklstring(L, 1, &buf_len);
    size_t new_len = 0;
    const char* new_data = luaL_checklstring(L, 2, &new_len);

    // Combine
    std::string combined;
    combined.reserve(buf_len + new_len);
    combined.append(buf, buf_len);
    combined.append(new_data, new_len);

    lua_newtable(L);  // result table
    int msg_count = 0;
    size_t pos = 0;

    while (pos + 2 <= combined.size()) {
        size_t payload_len = (static_cast<unsigned char>(combined[pos]) << 8)
                           |  static_cast<unsigned char>(combined[pos + 1]);
        if (pos + 2 + payload_len > combined.size()) {
            break;  // incomplete frame
        }

        msg_count++;
        lua_pushlstring(L, combined.data() + pos + 2, payload_len);
        lua_rawseti(L, -2, msg_count);
        pos += 2 + payload_len;
    }

    // Remaining buffer
    if (pos < combined.size()) {
        lua_pushlstring(L, combined.data() + pos, combined.size() - pos);
    } else {
        lua_pushliteral(L, "");
    }

    return 2;  // msgs_table, remaining
}

// ============================================================================
// netpack.tostring(msg, sz) → string
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
    return luaL_error(L, "netpack.tostring: invalid type");
}

// ============================================================================
// Module registration
// ============================================================================

extern "C" int luaopen_netpack(lua_State* L) {
    luaL_Reg funcs[] = {
        {"pack",     lpack},
        {"unpack",   lunpack},
        {"filter",   lfilter},
        {"tostring", ltostring},
        {nullptr, nullptr}
    };

    luaL_newlib(L, funcs);
    return 1;
}
