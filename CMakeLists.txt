cmake_minimum_required(VERSION 3.20)
project(skynet-cpp LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(SKYNET_ENABLE_COVERAGE "Enable LLVM source coverage instrumentation" OFF)

if(SKYNET_ENABLE_COVERAGE)
    if(NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang")
        message(FATAL_ERROR "SKYNET_ENABLE_COVERAGE requires clang/clang-cl")
    endif()
    add_compile_options(-fprofile-instr-generate -fcoverage-mapping)
    add_link_options(-fprofile-instr-generate -fcoverage-mapping)
endif()

# ---------------------------------------------------------------------------
# Dependencies (all in 3rdparty/)
# ---------------------------------------------------------------------------

# Asio (standalone, header-only)
add_library(asio INTERFACE)
target_include_directories(asio INTERFACE ${CMAKE_SOURCE_DIR}/3rdparty/asio)
target_compile_definitions(asio INTERFACE ASIO_STANDALONE)

if(WIN32)
    target_compile_definitions(asio INTERFACE _WIN32_WINNT=0x0A00)
    target_link_libraries(asio INTERFACE ws2_32)
endif()

# concurrentqueue (header-only)
add_library(concurrentqueue INTERFACE)
target_include_directories(concurrentqueue INTERFACE
    ${CMAKE_SOURCE_DIR}/3rdparty/concurrentqueue
)

# ---------------------------------------------------------------------------
# Lua 5.5.0 (Skynet's modified version, static library)
# ---------------------------------------------------------------------------

set(LUA_DIR ${CMAKE_SOURCE_DIR}/3rdparty/lua-5.5.0)

file(GLOB LUA_SOURCES ${LUA_DIR}/*.c)
# Exclude standalone executables and one-file build
list(REMOVE_ITEM LUA_SOURCES
    ${LUA_DIR}/lua.c
    ${LUA_DIR}/luac.c
    ${LUA_DIR}/onelua.c
    ${LUA_DIR}/ltests.c
)

add_library(lua STATIC ${LUA_SOURCES})
target_include_directories(lua PUBLIC ${LUA_DIR})
target_compile_definitions(lua PUBLIC LUA_USE_APICHECK)
if(MSVC)
    target_compile_definitions(lua PRIVATE _CRT_SECURE_NO_WARNINGS)
    target_compile_options(lua PRIVATE /W3)
else()
    target_compile_options(lua PRIVATE -Wall)
endif()

# ---------------------------------------------------------------------------
# lua-rapidjson (JSON support for Lua + C++ layer)
# ---------------------------------------------------------------------------

set(LUA_RAPIDJSON_DIR ${CMAKE_SOURCE_DIR}/3rdparty/lua-rapidjson)
set(RAPIDJSON_INCLUDE_DIR ${LUA_RAPIDJSON_DIR}/rapidjson/include)

# ---------------------------------------------------------------------------
# skynet-cpp executable
# ---------------------------------------------------------------------------

add_library(skynet-core-objects OBJECT
    src/platform.cpp
    src/skynet.cpp
    src/network.cpp
)
target_include_directories(skynet-core-objects PUBLIC src)
target_link_libraries(skynet-core-objects PUBLIC asio concurrentqueue)
if(MSVC)
    target_compile_definitions(skynet-core-objects PRIVATE _CRT_SECURE_NO_WARNINGS)
endif()

add_executable(skynet-cpp
    $<TARGET_OBJECTS:skynet-core-objects>
    src/lua_actor.cpp
    src/lua_binding.cpp
    src/lua_seri.cpp
    src/lua_socket_binding.cpp
    src/lua_netpack.cpp
    src/lua_profile.cpp
    src/lua_cluster.cpp
    src/main.cpp
    # lua-rapidjson sources
    ${LUA_RAPIDJSON_DIR}/src/rapidjson.cpp
    ${LUA_RAPIDJSON_DIR}/src/values.cpp
    ${LUA_RAPIDJSON_DIR}/src/Document.cpp
    ${LUA_RAPIDJSON_DIR}/src/Schema.cpp
)

target_include_directories(skynet-cpp PRIVATE
    src
    ${RAPIDJSON_INCLUDE_DIR}
    ${LUA_RAPIDJSON_DIR}/src
)
target_link_libraries(skynet-cpp PRIVATE asio concurrentqueue lua)

if(UNIX AND NOT APPLE)
    target_link_libraries(skynet-cpp PRIVATE pthread)
endif()

if(SKYNET_ENABLE_COVERAGE)
    add_executable(skynet-cpp-unit
        $<TARGET_OBJECTS:skynet-core-objects>
        tests/cpp_unit.cpp
    )
    target_include_directories(skynet-cpp-unit PRIVATE src)
    target_link_libraries(skynet-cpp-unit PRIVATE asio concurrentqueue)
endif()
