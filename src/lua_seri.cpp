// ============================================================================
// lua_seri.cpp — Lua value serialization (compatible with Skynet lua-seri.c)
//
// Binary format:
//   Each value: 1-byte header [TYPE:3 | COOKIE:5] + variable payload
//
// Types:
//   0 = nil
//   1 = boolean (cookie: 0=false, 1=true)
//   2 = number  (cookie: 0=zero,1=byte,2=word,4=dword,6=qword,8=double)
//   3 = userdata (lightuserdata, 8 bytes)
//   4 = short string (cookie = length, 0..31)
//   5 = long string  (cookie = 2 or 4: length field bytes)
//   6 = table (cookie = array_size if < 31, else 31 + packed integer)
// ============================================================================

#include "lua_seri.h"

#include <cassert>
#include <cstdint>
#include <cstdlib>
#include <cstring>

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

// Type codes
static constexpr int TYPE_NIL          = 0;
static constexpr int TYPE_BOOLEAN      = 1;
static constexpr int TYPE_NUMBER       = 2;
static constexpr int TYPE_USERDATA     = 3;
static constexpr int TYPE_SHORT_STRING = 4;
static constexpr int TYPE_LONG_STRING  = 5;
static constexpr int TYPE_TABLE        = 6;

// Number sub-types (stored in cookie)
static constexpr int TYPE_NUMBER_ZERO   = 0;
static constexpr int TYPE_NUMBER_BYTE   = 1;
static constexpr int TYPE_NUMBER_WORD   = 2;
static constexpr int TYPE_NUMBER_DWORD  = 4;
static constexpr int TYPE_NUMBER_QWORD  = 6;
static constexpr int TYPE_NUMBER_DOUBLE = 8;

static constexpr int MAX_COOKIE = 32;
static constexpr int MAX_DEPTH  = 32;

static inline uint8_t COMBINE_TYPE(int t, int v) {
    return static_cast<uint8_t>(t | (v << 3));
}

// ============================================================================
// Write buffer — linked list of blocks
// ============================================================================

static constexpr size_t BLOCK_SIZE = 128;

struct Block {
    Block* next = nullptr;
    char   buffer[BLOCK_SIZE];
};

struct WriteBlock {
    Block*  head;
    Block*  current;
    size_t  len;
    size_t  ptr;       // write position in current block

    void init(Block* first) {
        head = first;
        current = first;
        len = 0;
        ptr = 0;
        first->next = nullptr;
    }

    void push(const void* data, size_t sz) {
        const char* src = static_cast<const char*>(data);
        while (sz > 0) {
            size_t space = BLOCK_SIZE - ptr;
            if (space == 0) {
                auto* nb = static_cast<Block*>(std::malloc(sizeof(Block)));
                nb->next = nullptr;
                current->next = nb;
                current = nb;
                ptr = 0;
                space = BLOCK_SIZE;
            }
            size_t copy = sz < space ? sz : space;
            std::memcpy(current->buffer + ptr, src, copy);
            ptr += copy;
            src += copy;
            sz  -= copy;
            len += copy;
        }
    }

    void free_blocks() {
        Block* b = head->next;  // skip first (stack-allocated)
        while (b) {
            Block* next = b->next;
            std::free(b);
            b = next;
        }
        head->next = nullptr;
    }
};

// ============================================================================
// Read buffer
// ============================================================================

struct ReadBlock {
    const char* buffer;
    size_t      len;
    size_t      ptr;

    void init(const void* buf, size_t sz) {
        buffer = static_cast<const char*>(buf);
        len = sz;
        ptr = 0;
    }

    const void* read(size_t sz) {
        if (ptr + sz > len) return nullptr;
        const void* result = buffer + ptr;
        ptr += sz;
        return result;
    }
};

// ============================================================================
// Pack helpers
// ============================================================================

static void wb_nil(WriteBlock& wb) {
    uint8_t n = COMBINE_TYPE(TYPE_NIL, 0);
    wb.push(&n, 1);
}

static void wb_boolean(WriteBlock& wb, int v) {
    uint8_t n = COMBINE_TYPE(TYPE_BOOLEAN, v ? 1 : 0);
    wb.push(&n, 1);
}

static void wb_integer(WriteBlock& wb, lua_Integer v) {
    if (v == 0) {
        uint8_t n = COMBINE_TYPE(TYPE_NUMBER, TYPE_NUMBER_ZERO);
        wb.push(&n, 1);
    } else if (v != static_cast<int32_t>(v)) {
        uint8_t n = COMBINE_TYPE(TYPE_NUMBER, TYPE_NUMBER_QWORD);
        wb.push(&n, 1);
        int64_t v64 = static_cast<int64_t>(v);
        wb.push(&v64, 8);
    } else if (v < 0) {
        uint8_t n = COMBINE_TYPE(TYPE_NUMBER, TYPE_NUMBER_DWORD);
        wb.push(&n, 1);
        int32_t v32 = static_cast<int32_t>(v);
        wb.push(&v32, 4);
    } else if (v < 0x100) {
        uint8_t n = COMBINE_TYPE(TYPE_NUMBER, TYPE_NUMBER_BYTE);
        wb.push(&n, 1);
        uint8_t byte = static_cast<uint8_t>(v);
        wb.push(&byte, 1);
    } else if (v < 0x10000) {
        uint8_t n = COMBINE_TYPE(TYPE_NUMBER, TYPE_NUMBER_WORD);
        wb.push(&n, 1);
        uint16_t word = static_cast<uint16_t>(v);
        wb.push(&word, 2);
    } else {
        uint8_t n = COMBINE_TYPE(TYPE_NUMBER, TYPE_NUMBER_DWORD);
        wb.push(&n, 1);
        uint32_t v32 = static_cast<uint32_t>(v);
        wb.push(&v32, 4);
    }
}

static void wb_double(WriteBlock& wb, double v) {
    uint8_t n = COMBINE_TYPE(TYPE_NUMBER, TYPE_NUMBER_DOUBLE);
    wb.push(&n, 1);
    wb.push(&v, 8);
}

static void wb_pointer(WriteBlock& wb, void* v) {
    uint8_t n = COMBINE_TYPE(TYPE_USERDATA, 0);
    wb.push(&n, 1);
    wb.push(&v, sizeof(v));
}

static void wb_string(WriteBlock& wb, const char* str, size_t len) {
    if (len < MAX_COOKIE) {
        uint8_t n = COMBINE_TYPE(TYPE_SHORT_STRING, static_cast<int>(len));
        wb.push(&n, 1);
        if (len > 0) wb.push(str, len);
    } else if (len < 0x10000) {
        uint8_t n = COMBINE_TYPE(TYPE_LONG_STRING, 2);
        wb.push(&n, 1);
        uint16_t x = static_cast<uint16_t>(len);
        wb.push(&x, 2);
        wb.push(str, len);
    } else {
        uint8_t n = COMBINE_TYPE(TYPE_LONG_STRING, 4);
        wb.push(&n, 1);
        uint32_t x = static_cast<uint32_t>(len);
        wb.push(&x, 4);
        wb.push(str, len);
    }
}

static void pack_one(lua_State* L, WriteBlock& wb, int index, int depth);

static int wb_table_array(lua_State* L, WriteBlock& wb,
                          int index, int depth) {
    int array_size = static_cast<int>(lua_rawlen(L, index));
    if (array_size >= MAX_COOKIE - 1) {
        uint8_t n = COMBINE_TYPE(TYPE_TABLE, MAX_COOKIE - 1);
        wb.push(&n, 1);
        wb_integer(wb, array_size);
    } else {
        uint8_t n = COMBINE_TYPE(TYPE_TABLE, array_size);
        wb.push(&n, 1);
    }

    for (int i = 1; i <= array_size; i++) {
        lua_rawgeti(L, index, i);
        pack_one(L, wb, -1, depth);
        lua_pop(L, 1);
    }

    return array_size;
}

static void wb_table_hash(lua_State* L, WriteBlock& wb,
                          int index, int depth, int array_size) {
    lua_pushnil(L);
    while (lua_next(L, index) != 0) {
        if (lua_type(L, -2) == LUA_TNUMBER) {
            if (lua_isinteger(L, -2)) {
                lua_Integer x = lua_tointeger(L, -2);
                if (x > 0 && x <= array_size) {
                    lua_pop(L, 1);
                    continue;
                }
            }
        }
        pack_one(L, wb, -2, depth);  // key
        pack_one(L, wb, -1, depth);  // value
        lua_pop(L, 1);
    }
    wb_nil(wb);  // sentinel
}

static void wb_table(lua_State* L, WriteBlock& wb, int index, int depth) {
    if (index < 0) {
        index = lua_gettop(L) + index + 1;
    }
    if (depth >= MAX_DEPTH) {
        luaL_error(L, "serialize: table too deep (%d)", depth);
        return;
    }
    luaL_checkstack(L, 8, "serialize: table too deep");
    int array_size = wb_table_array(L, wb, index, depth);
    wb_table_hash(L, wb, index, depth, array_size);
}

static void pack_one(lua_State* L, WriteBlock& wb, int index, int depth) {
    int type = lua_type(L, index);
    switch (type) {
    case LUA_TNIL:
        wb_nil(wb);
        break;
    case LUA_TBOOLEAN:
        wb_boolean(wb, lua_toboolean(L, index));
        break;
    case LUA_TNUMBER:
        if (lua_isinteger(L, index)) {
            wb_integer(wb, lua_tointeger(L, index));
        } else {
            wb_double(wb, lua_tonumber(L, index));
        }
        break;
    case LUA_TLIGHTUSERDATA:
        wb_pointer(wb, lua_touserdata(L, index));
        break;
    case LUA_TSTRING: {
        size_t len = 0;
        const char* str = lua_tolstring(L, index, &len);
        wb_string(wb, str, len);
        break;
    }
    case LUA_TTABLE:
        wb_table(L, wb, index, depth + 1);
        break;
    default:
        luaL_error(L, "Unsupported type %s to serialize",
                   lua_typename(L, type));
        break;
    }
}

// Concat all blocks into a single malloc'd buffer, push as lightuserdata + size
static void seri(lua_State* L, WriteBlock& wb) {
    size_t sz = wb.len;
    void* buffer = std::malloc(sz);
    if (!buffer) {
        luaL_error(L, "serialize: out of memory (%zu bytes)", sz);
        return;
    }

    Block* b = wb.head;
    char* dst = static_cast<char*>(buffer);
    size_t remaining = sz;

    while (b && remaining > 0) {
        size_t copy = remaining;
        if (b == wb.current) {
            copy = wb.ptr;
        } else {
            copy = BLOCK_SIZE;
        }
        if (copy > remaining) copy = remaining;
        std::memcpy(dst, b->buffer, copy);
        dst += copy;
        remaining -= copy;
        b = b->next;
    }

    lua_pushlightuserdata(L, buffer);
    lua_pushinteger(L, static_cast<lua_Integer>(sz));
}

// ============================================================================
// Unpack helpers
// ============================================================================

static void unpack_one(lua_State* L, ReadBlock& rb);

static lua_Integer rb_integer(ReadBlock& rb, int cookie) {
    switch (cookie) {
    case TYPE_NUMBER_ZERO:
        return 0;
    case TYPE_NUMBER_BYTE: {
        auto* p = static_cast<const uint8_t*>(rb.read(1));
        if (!p) return 0;
        return *p;
    }
    case TYPE_NUMBER_WORD: {
        auto* p = static_cast<const uint16_t*>(rb.read(2));
        if (!p) return 0;
        uint16_t v;
        std::memcpy(&v, p, 2);
        return v;
    }
    case TYPE_NUMBER_DWORD: {
        auto* p = rb.read(4);
        if (!p) return 0;
        int32_t v;
        std::memcpy(&v, p, 4);
        return v;
    }
    case TYPE_NUMBER_QWORD: {
        auto* p = rb.read(8);
        if (!p) return 0;
        int64_t v;
        std::memcpy(&v, p, 8);
        return static_cast<lua_Integer>(v);
    }
    default:
        return 0;
    }
}

static double rb_double(ReadBlock& rb) {
    auto* p = rb.read(8);
    if (!p) return 0.0;
    double v;
    std::memcpy(&v, p, 8);
    return v;
}

static void* rb_pointer(ReadBlock& rb) {
    auto* p = rb.read(sizeof(void*));
    if (!p) return nullptr;
    void* v;
    std::memcpy(&v, p, sizeof(void*));
    return v;
}

static void rb_table(lua_State* L, ReadBlock& rb, int array_size) {
    lua_createtable(L, array_size, 0);

    // Array part
    for (int i = 1; i <= array_size; i++) {
        unpack_one(L, rb);
        lua_rawseti(L, -2, i);
    }

    // Hash part: pairs until nil sentinel
    for (;;) {
        auto* t = static_cast<const uint8_t*>(rb.read(1));
        if (!t) break;
        uint8_t type = *t & 0x7;
        int cookie = *t >> 3;
        if (type == TYPE_NIL) break;  // sentinel

        // Push key
        // We need to inline the unpack here since we already consumed the byte
        // Push based on type+cookie
        switch (type) {
        case TYPE_BOOLEAN:
            lua_pushboolean(L, cookie);
            break;
        case TYPE_NUMBER:
            if (cookie == TYPE_NUMBER_DOUBLE) {
                lua_pushnumber(L, rb_double(rb));
            } else {
                lua_pushinteger(L, rb_integer(rb, cookie));
            }
            break;
        case TYPE_SHORT_STRING: {
            auto* str = static_cast<const char*>(rb.read(cookie));
            if (str) lua_pushlstring(L, str, cookie);
            else lua_pushnil(L);
            break;
        }
        case TYPE_LONG_STRING: {
            uint32_t len = 0;
            if (cookie == 2) {
                auto* p = rb.read(2);
                if (p) { uint16_t v; std::memcpy(&v, p, 2); len = v; }
            } else {
                auto* p = rb.read(4);
                if (p) std::memcpy(&len, p, 4);
            }
            auto* str = static_cast<const char*>(rb.read(len));
            if (str) lua_pushlstring(L, str, len);
            else lua_pushnil(L);
            break;
        }
        case TYPE_USERDATA:
            lua_pushlightuserdata(L, rb_pointer(rb));
            break;
        case TYPE_TABLE: {
            int sz = cookie;
            if (sz == MAX_COOKIE - 1) {
                // Need to read array size
                auto* st = static_cast<const uint8_t*>(rb.read(1));
                if (st) {
                    sz = static_cast<int>(rb_integer(rb, *st >> 3));
                }
            }
            rb_table(L, rb, sz);
            break;
        }
        default:
            lua_pushnil(L);
            break;
        }

        // Push value
        unpack_one(L, rb);

        lua_rawset(L, -3);
    }
}

static void unpack_one(lua_State* L, ReadBlock& rb) {
    auto* t = static_cast<const uint8_t*>(rb.read(1));
    if (!t) {
        lua_pushnil(L);
        return;
    }

    int type = *t & 0x7;
    int cookie = *t >> 3;

    switch (type) {
    case TYPE_NIL:
        lua_pushnil(L);
        break;
    case TYPE_BOOLEAN:
        lua_pushboolean(L, cookie);
        break;
    case TYPE_NUMBER:
        if (cookie == TYPE_NUMBER_DOUBLE) {
            lua_pushnumber(L, rb_double(rb));
        } else {
            lua_pushinteger(L, rb_integer(rb, cookie));
        }
        break;
    case TYPE_USERDATA:
        lua_pushlightuserdata(L, rb_pointer(rb));
        break;
    case TYPE_SHORT_STRING: {
        auto* str = static_cast<const char*>(rb.read(cookie));
        if (str) lua_pushlstring(L, str, cookie);
        else lua_pushnil(L);
        break;
    }
    case TYPE_LONG_STRING: {
        uint32_t len = 0;
        if (cookie == 2) {
            auto* p = rb.read(2);
            if (p) { uint16_t v; std::memcpy(&v, p, 2); len = v; }
        } else {
            auto* p = rb.read(4);
            if (p) std::memcpy(&len, p, 4);
        }
        auto* str = static_cast<const char*>(rb.read(len));
        if (str) lua_pushlstring(L, str, len);
        else lua_pushnil(L);
        break;
    }
    case TYPE_TABLE: {
        int array_size = cookie;
        if (array_size == MAX_COOKIE - 1) {
            // Read extended array size
            auto* st = static_cast<const uint8_t*>(rb.read(1));
            if (st) {
                array_size = static_cast<int>(rb_integer(rb, *st >> 3));
            }
        }
        rb_table(L, rb, array_size);
        break;
    }
    default:
        lua_pushnil(L);
        break;
    }
}

// ============================================================================
// Public API
// ============================================================================

int luaseri_pack(lua_State* L) {
    Block temp;
    WriteBlock wb;
    wb.init(&temp);

    int n = lua_gettop(L);
    for (int i = 1; i <= n; i++) {
        pack_one(L, wb, i, 0);
    }

    seri(L, wb);
    wb.free_blocks();
    return 2;  // lightuserdata, size
}

static int unpack_impl(lua_State* L, bool free_lightuserdata) {
    ReadBlock rb;
    void* buffer_to_free = nullptr;
    if (lua_type(L, 1) == LUA_TSTRING) {
        size_t sz = 0;
        const char* str = lua_tolstring(L, 1, &sz);
        rb.init(str, sz);
    } else {
        void* buffer = lua_touserdata(L, 1);
        int sz = static_cast<int>(luaL_checkinteger(L, 2));
        rb.init(buffer, static_cast<size_t>(sz));
        if (free_lightuserdata) {
            buffer_to_free = buffer;
        }
    }

    lua_settop(L, 0);

    int count = 0;
    while (rb.ptr < rb.len) {
        if (count % 8 == 7) {
            luaL_checkstack(L, LUA_MINSTACK, nullptr);
        }
        unpack_one(L, rb);
        ++count;
    }

    if (buffer_to_free) {
        std::free(buffer_to_free);
    }

    return count;
}

int luaseri_unpack(lua_State* L) {
    return unpack_impl(L, false);
}

int luaseri_unpacktrash(lua_State* L) {
    return unpack_impl(L, true);
}
