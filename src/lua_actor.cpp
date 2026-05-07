#include "lua_actor.h"
#include "network.h"
#include "platform.h"
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <mutex>

// Forward declare the module openers
extern "C" int luaopen_skynet_core(lua_State* L);
extern "C" int luaopen_rapidjson(lua_State* L);
extern "C" int luaopen_socketdriver(lua_State* L);
extern "C" int luaopen_netpack(lua_State* L);
extern "C" int luaopen_skynet_profile(lua_State* L);
extern "C" int luaopen_cluster_core(lua_State* L);

static std::string normalize_runtime_path(std::string path) {
    for (auto& c : path) {
        if (c == '\\') c = '/';
    }
    while (path.size() > 1 && path.back() == '/') {
        path.pop_back();
    }
    return path;
}

static bool is_absolute_path(const std::string& path) {
    return !path.empty() &&
        (path[0] == '/' || path[0] == '\\' ||
         (path.size() >= 2 && path[1] == ':'));
}

static bool file_exists(const std::string& path) {
    std::error_code ec;
    return std::filesystem::is_regular_file(std::filesystem::path(path), ec);
}

static std::string find_bootstrap_lualib_dir() {
    std::string cwd = normalize_runtime_path(skynet::platform::current_path());
    std::string candidate = cwd + "/lualib/loader.lua";
    if (file_exists(candidate)) {
        return cwd + "/lualib";
    }

    candidate = cwd + "/skynet-cpp/lualib/loader.lua";
    if (file_exists(candidate)) {
        return cwd + "/skynet-cpp/lualib";
    }

    return cwd + "/lualib";
}

static std::string resolve_cwd_path(const std::string& path) {
    if (path.empty() || is_absolute_path(path)) {
        return normalize_runtime_path(path);
    }
    return normalize_runtime_path(skynet::platform::current_path() + "/" + path);
}

// Initialize Lua codecache spinlock once
static std::once_flag s_codecache_once;
static void ensure_codecache() {
    std::call_once(s_codecache_once, [] {
        luaL_initcodecache();
    });
}

static void free_owned_lua_payload(const skynet::Message& msg) {
    if (auto* sd = msg.get_if<skynet::SeriData>()) {
        std::free(sd->data);
    }
}

namespace skynet {

// ============================================================================
// Memory allocator with tracking (mirrors service_snlua.c lalloc)
// ============================================================================

void* LuaActor::lua_alloc(void* ud, void* ptr, size_t osize, size_t nsize) {
    auto* self = static_cast<LuaActor*>(ud);
    size_t old_mem = self->mem_;
    size_t new_mem = old_mem + nsize;
    if (ptr) new_mem -= osize;

    // Enforce memory limit
    if (self->mem_limit_ != 0 && new_mem > self->mem_limit_) {
        if (ptr == nullptr || nsize > osize) {
            return nullptr;
        }
    }

    if (nsize == 0) {
        std::free(ptr);
        self->mem_ = new_mem;
        return nullptr;
    }

    void* new_ptr = std::realloc(ptr, nsize);
    if (!new_ptr) {
        return nullptr;
    }
    self->mem_ = new_mem;

    // Memory warning
    if (self->mem_ > self->mem_report_) {
        self->mem_report_ *= 2;
        self->system().error(self->handle(),
            "Lua memory warning: %.2f MB",
            static_cast<double>(self->mem_) / (1024.0 * 1024.0));
    }

    return new_ptr;
}

// ============================================================================
// Constructor / Destructor
// ============================================================================

LuaActor::LuaActor() = default;

LuaActor::~LuaActor() {
    if (L_) {
        lua_close(L_);
        L_ = nullptr;
    }
}

void LuaActor::set_callback_ref(int ref) {
    if (!L_) {
        return;
    }
    if (callback_ref_ != LUA_NOREF) {
        luaL_unref(L_, LUA_REGISTRYINDEX, callback_ref_);
    }
    callback_ref_ = ref;
    has_callback_ = callback_ref_ != LUA_NOREF;
}

// ============================================================================
// on_init -- create Lua state, load script via loader
// ============================================================================

static int traceback(lua_State* L) {
    const char* msg = lua_tostring(L, 1);
    if (msg) {
        luaL_traceback(L, L, msg, 1);
    } else {
        lua_pushliteral(L, "(no error message)");
    }
    return 1;
}

void LuaActor::setup_lua_paths() {
    std::string bootstrap_lualib = find_bootstrap_lualib_dir();
    auto paths = system().lua_path_config();

    std::string bootstrap_lua_path = bootstrap_lualib + "/?.lua;"
                                  + bootstrap_lualib + "/?/init.lua";
    lua_pushstring(L_, bootstrap_lua_path.c_str());
    lua_setglobal(L_, "BOOTSTRAP_LUA_PATH");

    lua_pushstring(L_, paths.path.c_str());
    lua_setglobal(L_, "LUA_PATH");

    lua_pushstring(L_, paths.cpath.c_str());
    lua_setglobal(L_, "LUA_CPATH");

    lua_pushstring(L_, paths.service_path.c_str());
    lua_setglobal(L_, "LUA_SERVICE");
}

void LuaActor::on_init(std::string_view param) {
    // Initialize codecache if not done
    ensure_codecache();

    // 1. Create Lua state with tracked allocator
    unsigned seed = static_cast<unsigned>(handle()) ^ 
        static_cast<unsigned>(std::chrono::steady_clock::now()
            .time_since_epoch().count());
    L_ = lua_newstate(lua_alloc, this, seed);
    if (!L_) {
        mark_init_failed();
        system().error(handle(), "LuaActor: failed to create lua_State");
        return;
    }

    // 2. Stop GC during init
    lua_gc(L_, LUA_GCSTOP, 0);

    // 3. Open selected standard libraries (no io/os for sandboxing)
    int libs = LUA_GLIBK | LUA_LOADLIBK | LUA_COLIBK | LUA_DBLIBK
             | LUA_MATHLIBK | LUA_STRLIBK | LUA_TABLIBK | LUA_UTF8LIBK;
    luaL_openselectedlibs(L_, libs, 0);

    // 3a. Open the cache library and set mode to OFF
    luaL_requiref(L_, "cache", luaopen_cache, 1);
    lua_pop(L_, 1);

    // 3b. Load skynet.profile and replace coroutine.resume/wrap
    luaL_requiref(L_, "skynet.profile", luaopen_skynet_profile, 0);
    int profile_lib = lua_gettop(L_);

    lua_getglobal(L_, "coroutine");
    lua_getfield(L_, profile_lib, "resume");
    lua_setfield(L_, -2, "resume");
    lua_getfield(L_, profile_lib, "wrap");
    lua_setfield(L_, -2, "wrap");
    lua_settop(L_, profile_lib - 1);

    // 3c. Preload built-in C modules
    luaL_getsubtable(L_, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
    lua_pushcfunction(L_, luaopen_skynet_core);
    lua_setfield(L_, -2, "skynet.core");
    lua_pushcfunction(L_, luaopen_rapidjson);
    lua_setfield(L_, -2, "rapidjson");
    lua_pushcfunction(L_, luaopen_socketdriver);
    lua_setfield(L_, -2, "socketdriver");
    lua_pushcfunction(L_, luaopen_netpack);
    lua_setfield(L_, -2, "netpack");
    lua_pushcfunction(L_, luaopen_skynet_profile);
    lua_setfield(L_, -2, "skynet.profile");
    lua_pushcfunction(L_, luaopen_cluster_core);
    lua_setfield(L_, -2, "cluster.core");
    lua_pop(L_, 1);  // pop preload table

    // 4. Store 'this' pointer in registry for C bindings to access
    lua_pushlightuserdata(L_, this);
    lua_setfield(L_, LUA_REGISTRYINDEX, "skynet_actor");

    lua_pushcfunction(L_, traceback);
    traceback_ref_ = luaL_ref(L_, LUA_REGISTRYINDEX);

    // 5. Set paths
    setup_lua_paths();

    // 6. Push traceback function at stack position 1
    lua_rawgeti(L_, LUA_REGISTRYINDEX, traceback_ref_);  // [1] = traceback

    // 7. Load and run loader.lua
    std::string loader_path = find_bootstrap_lualib_dir() + "/loader.lua";
    int r = luaL_loadfilex_(L_, loader_path.c_str(), nullptr);
    if (r != LUA_OK) {
        mark_init_failed();
        system().error(handle(), "LuaActor: failed to load loader.lua: %s",
                       lua_tostring(L_, -1));
        lua_pop(L_, 1);
        return;
    }

    // Pass param (script name) as argument to loader. Plain service names must
    // stay plain so loader.lua can resolve them through LUA_SERVICE.
    std::string script_param(param);
    size_t first_space = script_param.find(' ');
    std::string script_name = first_space == std::string::npos
        ? script_param
        : script_param.substr(0, first_space);
    bool is_absolute = is_absolute_path(script_name);
    bool is_path = script_name.find('/') != std::string::npos ||
                   script_name.find('\\') != std::string::npos ||
                   script_name.find(".lua") != std::string::npos;
    if (!script_name.empty() && !is_absolute && is_path) {
        std::string rest = first_space == std::string::npos
            ? std::string()
            : script_param.substr(first_space);
        script_param = resolve_cwd_path(script_name) + rest;
    }
    lua_pushlstring(L_, script_param.data(), script_param.size());
    r = lua_pcall(L_, 1, 0, 1);  // loader(param), traceback at 1
    if (r != LUA_OK) {
        mark_init_failed();
        system().error(handle(), "LuaActor: loader failed: %s",
                       lua_tostring(L_, -1));
        lua_pop(L_, 1);
        return;
    }

    // 9. Restart GC
    lua_gc(L_, LUA_GCRESTART, 0);

    lua_settop(L_, 0);
}

// ============================================================================
// on_message -- dispatch to Lua callback
//
// Skynet pattern: callback(type, msg, sz, session, source)
//   msg  = lightuserdata (pointer to serialized data) or string
//   sz   = integer (byte length)
// ============================================================================

void LuaActor::on_message(const Message& msg) {
    if (!L_ || !has_callback_) {
        free_owned_lua_payload(msg);
        return;
    }

    // Push traceback
    lua_rawgeti(L_, LUA_REGISTRYINDEX, traceback_ref_);
    int trace = lua_gettop(L_);

    // Push the callback function
    lua_rawgeti(L_, LUA_REGISTRYINDEX, callback_ref_);
    if (lua_isnil(L_, -1)) {
        lua_settop(L_, 0);
        return;
    }

    // Arg 1: type (integer)
    lua_pushinteger(L_, msg.type);

    // Arg 2 & 3: msg + sz
    // For PTYPE_LUA: data is SeriData (lightuserdata + size)
    // For PTYPE_TEXT/PTYPE_ERROR: data is std::string
    // For PTYPE_RESPONSE: data is SeriData
    // For PTYPE_SOCKET: convert socket event structs to Lua table
    // For PTYPE_TIMER: no data
    if (msg.type == PTYPE_LUA || msg.type == PTYPE_RESPONSE ||
        msg.type == PTYPE_MULTICAST || msg.type == PTYPE_DEBUG) {
        if (auto* sd = msg.get_if<SeriData>()) {
            lua_pushlightuserdata(L_, sd->data);
            lua_pushinteger(L_, static_cast<lua_Integer>(sd->size));
        } else if (auto* text = msg.get_if<std::string>()) {
            lua_pushlstring(L_, text->data(), text->size());
            lua_pushinteger(L_, static_cast<lua_Integer>(text->size()));
        } else {
            lua_pushnil(L_);
            lua_pushinteger(L_, 0);
        }
    } else if (msg.type == PTYPE_TEXT || msg.type == PTYPE_ERROR) {
        if (auto* text = msg.get_if<std::string>()) {
            lua_pushlstring(L_, text->data(), text->size());
            lua_pushinteger(L_, static_cast<lua_Integer>(text->size()));
        } else {
            lua_pushnil(L_);
            lua_pushinteger(L_, 0);
        }
    } else if (msg.type == PTYPE_SOCKET) {
        // Socket events are internally typed C++ payloads, but Lua keeps the
        // compact string ABI for performance and compatibility.
        std::string encoded;
        if (auto* ev = msg.get_if<SocketAccept>()) {
            encoded = "accept " + std::to_string(ev->listener_id)
                    + " " + std::to_string(ev->connection_id)
                    + " " + ev->remote_address
                    + " " + std::to_string(ev->remote_port);
        } else if (auto* ev = msg.get_if<SocketData>()) {
            encoded = "data " + std::to_string(ev->listener_id)
                    + " " + std::to_string(ev->connection_id) + " ";
            encoded.append(ev->data);
        } else if (auto* ev = msg.get_if<SocketClose>()) {
            encoded = "close " + std::to_string(ev->listener_id)
                    + " " + std::to_string(ev->connection_id);
        } else if (auto* ev = msg.get_if<SocketOpen>()) {
            encoded = "open " + std::to_string(ev->connection_id)
                    + " " + ev->remote_address
                    + " " + std::to_string(ev->remote_port);
        } else if (auto* ev = msg.get_if<SocketWarning>()) {
            encoded = "warning " + std::to_string(ev->listener_id)
                    + " " + std::to_string(ev->connection_id)
                    + " " + std::to_string(ev->pending_bytes);
        } else if (auto* ev = msg.get_if<SocketUDP>()) {
            encoded = "udp " + std::to_string(ev->socket_id)
                    + " " + ev->remote_address
                    + " " + std::to_string(ev->remote_port) + " ";
            encoded.append(ev->data);
        } else {
            encoded = "unknown";
        }
        lua_pushlstring(L_, encoded.data(), encoded.size());
        lua_pushinteger(L_, static_cast<lua_Integer>(encoded.size()));
    } else {
        // PTYPE_TIMER, etc. - no payload
        lua_pushnil(L_);
        lua_pushinteger(L_, 0);
    }

    // Arg 4: session
    lua_pushinteger(L_, msg.session);

    // Arg 5: source
    lua_pushinteger(L_, msg.source);

    // Call: callback(type, msg, sz, session, source)
    int r = lua_pcall(L_, 5, 0, trace);
    if (r != LUA_OK) {
        system().error(handle(), "LuaActor callback error: %s",
                       lua_tostring(L_, -1));
        lua_pop(L_, 1);
    }

    lua_settop(L_, 0);
}

// ============================================================================
// on_destroy
// ============================================================================

void LuaActor::on_destroy() {
    if (L_) {
        if (callback_ref_ != LUA_NOREF) {
            luaL_unref(L_, LUA_REGISTRYINDEX, callback_ref_);
            callback_ref_ = LUA_NOREF;
            has_callback_ = false;
        }
        if (traceback_ref_ != LUA_NOREF) {
            luaL_unref(L_, LUA_REGISTRYINDEX, traceback_ref_);
            traceback_ref_ = LUA_NOREF;
        }
        lua_getglobal(L_, "package");
        if (lua_istable(L_, -1)) {
            lua_getfield(L_, -1, "loaded");
            if (lua_istable(L_, -1)) {
                lua_getfield(L_, -1, "skynet.coverage");
                if (lua_istable(L_, -1)) {
                    lua_getfield(L_, -1, "flush");
                    if (lua_isfunction(L_, -1)) {
                        if (lua_pcall(L_, 0, 0, 0) != LUA_OK) {
                            lua_pop(L_, 1);
                        }
                    } else {
                        lua_pop(L_, 1);
                    }
                }
            }
        }
        lua_settop(L_, 0);
        lua_close(L_);
        L_ = nullptr;
    }
}

} // namespace skynet
