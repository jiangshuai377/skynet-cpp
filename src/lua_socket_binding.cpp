// lua_socket_binding.cpp — C module "socketdriver" for Lua
//
// Provides low-level socket operations:
//   socketdriver.listen(host, port)     → listener_id
//   socketdriver.connect(host, port)    → conn_id (async, result via SOCKET event)
//   socketdriver.send(id, data)         → bool
//   socketdriver.close(id)              → nil
//   socketdriver.nodelay(id)            → nil
//   socketdriver.pause(id)              → nil
//   socketdriver.resume(id)             → nil
//   socketdriver.udp(host, port)        → udp_id
//   socketdriver.udp_send(id,data,addr,port) → nil
//
// Socket events arrive as PTYPE_SOCKET messages.

#include "lua_actor.h"
#include "network.h"

#include <mutex>
#include <string>
#include <unordered_map>
#include <variant>

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

using namespace skynet;

// ============================================================================
// Per-actor socket storage — stored in Lua registry
// ============================================================================

struct SocketEntry {
    enum Type { LISTENER, CONNECTOR, UDP };
    Type type;
    std::shared_ptr<TcpListener>  listener;
    std::shared_ptr<TcpConnector> connector;
    std::shared_ptr<UdpSocket>    udp;
};

struct SocketStore {
    std::mutex mutex;
    std::unordered_map<int, SocketEntry> sockets;
    int next_id = 1;

    int alloc_id() { return next_id++; }
};

static const char* SOCKET_STORE_KEY = "skynet_socket_store";

static SocketStore* get_store(lua_State* L) {
    lua_getfield(L, LUA_REGISTRYINDEX, SOCKET_STORE_KEY);
    auto* store = static_cast<SocketStore*>(lua_touserdata(L, -1));
    lua_pop(L, 1);
    return store;
}

static LuaActor* get_actor(lua_State* L) {
    lua_getfield(L, LUA_REGISTRYINDEX, "skynet_actor");
    auto* actor = static_cast<LuaActor*>(lua_touserdata(L, -1));
    lua_pop(L, 1);
    return actor;
}

// ============================================================================
// socketdriver.listen(host, port [, backlog]) → listener_id
// ============================================================================

static int llisten(lua_State* L) {
    auto* actor = get_actor(L);
    auto* store = get_store(L);
    if (!actor || !store) return luaL_error(L, "no socket context");

    const char* host = luaL_checkstring(L, 1);
    int port = static_cast<int>(luaL_checkinteger(L, 2));

    int id;
    {
        std::lock_guard lock(store->mutex);
        id = store->alloc_id();
    }

    auto listener = std::make_shared<TcpListener>(
        actor->system(), actor->handle(),
        static_cast<uint16_t>(port), id, std::string(host),
        true /* nodelay */);

    {
        std::lock_guard lock(store->mutex);
        SocketEntry entry;
        entry.type = SocketEntry::LISTENER;
        entry.listener = listener;
        store->sockets[id] = std::move(entry);
    }

    listener->start();

    lua_pushinteger(L, id);
    return 1;
}

// ============================================================================
// socketdriver.connect(host, port) → conn_id
// Connection result arrives as SocketOpen or SocketClose event.
// ============================================================================

static int lconnect(lua_State* L) {
    auto* actor = get_actor(L);
    auto* store = get_store(L);
    if (!actor || !store) return luaL_error(L, "no socket context");

    const char* host = luaL_checkstring(L, 1);
    int port = static_cast<int>(luaL_checkinteger(L, 2));

    auto connector = std::make_shared<TcpConnector>(
        actor->system(), actor->handle(),
        std::string(host), static_cast<uint16_t>(port), true);

    int id = connector->id();  // TcpConnector has its own id
    connector->start();

    {
        std::lock_guard lock(store->mutex);
        SocketEntry entry;
        entry.type = SocketEntry::CONNECTOR;
        entry.connector = connector;
        store->sockets[id] = std::move(entry);
    }

    lua_pushinteger(L, id);
    return 1;
}

// ============================================================================
// socketdriver.send(id, data) → bool
// ============================================================================

static int lsocketsend(lua_State* L) {
    auto* store = get_store(L);
    if (!store) return luaL_error(L, "no socket context");

    int id = static_cast<int>(luaL_checkinteger(L, 1));
    size_t len = 0;
    const char* data = luaL_checklstring(L, 2, &len);

    std::shared_ptr<TcpConnector> connector;
    {
        std::lock_guard lock(store->mutex);
        auto it = store->sockets.find(id);
        if (it != store->sockets.end() &&
            it->second.type == SocketEntry::CONNECTOR) {
            connector = it->second.connector;
        }
    }

    if (connector) {
        connector->send(std::string(data, len));
        lua_pushboolean(L, 1);
        return 1;
    }

    lua_pushboolean(L, 0);
    return 1;
}

// ============================================================================
// socketdriver.write(listener_id, conn_id, data) → bool
// Send data on a connection owned by a listener.
// ============================================================================

static int lwrite(lua_State* L) {
    auto* store = get_store(L);
    if (!store) return luaL_error(L, "no socket context");

    int listener_id = static_cast<int>(luaL_checkinteger(L, 1));
    int conn_id = static_cast<int>(luaL_checkinteger(L, 2));
    size_t len = 0;
    const char* data = luaL_checklstring(L, 3, &len);

    std::shared_ptr<TcpListener> listener;
    {
        std::lock_guard lock(store->mutex);
        auto it = store->sockets.find(listener_id);
        if (it != store->sockets.end() &&
            it->second.type == SocketEntry::LISTENER) {
            listener = it->second.listener;
        }
    }

    if (!listener) {
        lua_pushboolean(L, 0);
        return 1;
    }

    listener->send(conn_id, std::string(data, len));
    lua_pushboolean(L, 1);
    return 1;
}

// ============================================================================
// socketdriver.close(id [, conn_id]) → nil
// If conn_id is provided, close a connection within a listener.
// Otherwise close the socket/listener itself.
// ============================================================================

static int lclose(lua_State* L) {
    auto* store = get_store(L);
    if (!store) return luaL_error(L, "no socket context");

    int id = static_cast<int>(luaL_checkinteger(L, 1));

    // Check if closing a specific connection within a listener
    if (lua_gettop(L) >= 2 && !lua_isnil(L, 2)) {
        int conn_id = static_cast<int>(luaL_checkinteger(L, 2));
        std::shared_ptr<TcpListener> listener;
        {
            std::lock_guard lock(store->mutex);
            auto it = store->sockets.find(id);
            if (it != store->sockets.end() &&
                it->second.type == SocketEntry::LISTENER) {
                listener = it->second.listener;
            }
        }
        if (listener) {
            listener->close_connection(conn_id);
        }
        return 0;
    }

    // Close the whole socket
    SocketEntry entry;
    {
        std::lock_guard lock(store->mutex);
        auto it = store->sockets.find(id);
        if (it == store->sockets.end()) return 0;
        entry = std::move(it->second);
        store->sockets.erase(it);
    }

    if (entry.type == SocketEntry::LISTENER && entry.listener) {
        entry.listener->stop();
    } else if (entry.type == SocketEntry::CONNECTOR && entry.connector) {
        entry.connector->close();
    } else if (entry.type == SocketEntry::UDP && entry.udp) {
        entry.udp->stop();
    }

    return 0;
}

// ============================================================================
// socketdriver.pause(listener_id, conn_id) → nil
// ============================================================================

static int lpause(lua_State* L) {
    auto* store = get_store(L);
    if (!store) return luaL_error(L, "no socket context");

    int listener_id = static_cast<int>(luaL_checkinteger(L, 1));
    int conn_id = static_cast<int>(luaL_checkinteger(L, 2));

    std::shared_ptr<TcpListener> listener;
    {
        std::lock_guard lock(store->mutex);
        auto it = store->sockets.find(listener_id);
        if (it != store->sockets.end() &&
            it->second.type == SocketEntry::LISTENER) {
            listener = it->second.listener;
        }
    }
    if (listener) {
        auto conn = listener->get_connection(conn_id);
        if (conn) {
            conn->pause();
        }
    }
    return 0;
}

// ============================================================================
// socketdriver.resume(listener_id, conn_id) → nil
// ============================================================================

static int lresume(lua_State* L) {
    auto* store = get_store(L);
    if (!store) return luaL_error(L, "no socket context");

    int listener_id = static_cast<int>(luaL_checkinteger(L, 1));
    int conn_id = static_cast<int>(luaL_checkinteger(L, 2));

    std::shared_ptr<TcpListener> listener;
    {
        std::lock_guard lock(store->mutex);
        auto it = store->sockets.find(listener_id);
        if (it != store->sockets.end() &&
            it->second.type == SocketEntry::LISTENER) {
            listener = it->second.listener;
        }
    }
    if (listener) {
        auto conn = listener->get_connection(conn_id);
        if (conn) {
            conn->resume();
        }
    }
    return 0;
}

// ============================================================================
// socketdriver.udp(host, port) → udp_id
// ============================================================================

static int ludp(lua_State* L) {
    auto* actor = get_actor(L);
    auto* store = get_store(L);
    if (!actor || !store) return luaL_error(L, "no socket context");

    const char* host = luaL_checkstring(L, 1);
    int port = static_cast<int>(luaL_checkinteger(L, 2));

    int id;
    {
        std::lock_guard lock(store->mutex);
        id = store->alloc_id();
    }

    auto udp = std::make_shared<UdpSocket>(
        actor->system(), actor->handle(), id, std::string(host),
        static_cast<uint16_t>(port));

    {
        std::lock_guard lock(store->mutex);
        SocketEntry entry;
        entry.type = SocketEntry::UDP;
        entry.udp = udp;
        store->sockets[id] = std::move(entry);
    }

    udp->start();

    lua_pushinteger(L, id);
    return 1;
}

// ============================================================================
// socketdriver.udp_send(id, data, host, port) → nil
// ============================================================================

static int ludp_send(lua_State* L) {
    auto* store = get_store(L);
    if (!store) return luaL_error(L, "no socket context");

    int id = static_cast<int>(luaL_checkinteger(L, 1));
    size_t len = 0;
    const char* data = luaL_checklstring(L, 2, &len);
    const char* host = luaL_checkstring(L, 3);
    int port = static_cast<int>(luaL_checkinteger(L, 4));

    std::shared_ptr<UdpSocket> udp;
    {
        std::lock_guard lock(store->mutex);
        auto it = store->sockets.find(id);
        if (it != store->sockets.end() &&
            it->second.type == SocketEntry::UDP) {
            udp = it->second.udp;
        }
    }
    if (udp) {
        udp->send_to(std::string(data, len), std::string(host),
                     static_cast<uint16_t>(port));
    }
    return 0;
}

// ============================================================================
// socketdriver.unpackevent(event_ptr) -> subtype, ...
// ============================================================================

static int lunpack_event(lua_State* L) {
    auto* payload = static_cast<MessagePayload*>(lua_touserdata(L, 1));
    if (!payload) {
        lua_pushliteral(L, "unknown");
        return 1;
    }

    if (auto* ev = std::get_if<SocketAccept>(payload)) {
        lua_pushliteral(L, "accept");
        lua_pushinteger(L, ev->listener_id);
        lua_pushinteger(L, ev->connection_id);
        lua_pushlstring(L, ev->remote_address.data(), ev->remote_address.size());
        lua_pushinteger(L, ev->remote_port);
        return 5;
    }
    if (auto* ev = std::get_if<SocketData>(payload)) {
        lua_pushliteral(L, "data");
        lua_pushinteger(L, ev->listener_id);
        lua_pushinteger(L, ev->connection_id);
        lua_pushlstring(L, ev->data.data(), ev->data.size());
        return 4;
    }
    if (auto* ev = std::get_if<SocketClose>(payload)) {
        lua_pushliteral(L, "close");
        lua_pushinteger(L, ev->listener_id);
        lua_pushinteger(L, ev->connection_id);
        return 3;
    }
    if (auto* ev = std::get_if<SocketOpen>(payload)) {
        lua_pushliteral(L, "open");
        lua_pushinteger(L, ev->connection_id);
        lua_pushlstring(L, ev->remote_address.data(), ev->remote_address.size());
        lua_pushinteger(L, ev->remote_port);
        return 4;
    }
    if (auto* ev = std::get_if<SocketWarning>(payload)) {
        lua_pushliteral(L, "warning");
        lua_pushinteger(L, ev->listener_id);
        lua_pushinteger(L, ev->connection_id);
        lua_pushinteger(L, static_cast<lua_Integer>(ev->pending_bytes));
        return 4;
    }
    if (auto* ev = std::get_if<SocketUDP>(payload)) {
        lua_pushliteral(L, "udp");
        lua_pushinteger(L, ev->socket_id);
        lua_pushlstring(L, ev->remote_address.data(), ev->remote_address.size());
        lua_pushinteger(L, ev->remote_port);
        lua_pushlstring(L, ev->data.data(), ev->data.size());
        return 5;
    }

    lua_pushliteral(L, "unknown");
    return 1;
}

// ============================================================================
// Module registration
// ============================================================================

extern "C" int luaopen_socketdriver(lua_State* L) {
    luaL_Reg funcs[] = {
        {"listen",     llisten},
        {"connect",    lconnect},
        {"send",       lsocketsend},
        {"write",      lwrite},
        {"close",      lclose},
        {"pause",      lpause},
        {"resume",     lresume},
        {"udp",        ludp},
        {"udp_send",   ludp_send},
        {"unpackevent", lunpack_event},
        {nullptr, nullptr}
    };

    // Create the SocketStore and store in registry
    lua_getfield(L, LUA_REGISTRYINDEX, SOCKET_STORE_KEY);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        auto* store = static_cast<SocketStore*>(
            lua_newuserdata(L, sizeof(SocketStore)));
        new (store) SocketStore();
        lua_setfield(L, LUA_REGISTRYINDEX, SOCKET_STORE_KEY);
    } else {
        lua_pop(L, 1);
    }

    luaL_newlib(L, funcs);
    return 1;
}
