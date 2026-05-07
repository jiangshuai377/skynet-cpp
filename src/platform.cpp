#include "platform.h"

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <random>
#include <sstream>
#include <thread>

namespace skynet::platform {

namespace {

std::string make_node_name() {
    static std::atomic<unsigned long long> seq{0};
    const auto now = std::chrono::system_clock::now().time_since_epoch().count();
    const auto tid = std::hash<std::thread::id>{}(std::this_thread::get_id());
    std::random_device rd;

    std::ostringstream out;
    out << "node"
        << std::hex
        << static_cast<unsigned long long>(now)
        << static_cast<unsigned long long>(tid)
        << static_cast<unsigned long long>(rd())
        << seq.fetch_add(1, std::memory_order_relaxed);
    return out.str();
}

} // namespace

std::string getenv_string(std::string_view name) {
    std::string key(name);
    const char* value = std::getenv(key.c_str());
    return value ? std::string(value) : std::string();
}

std::string current_path() {
    std::error_code ec;
    auto path = std::filesystem::current_path(ec);
    if (ec) {
        return ".";
    }
    return path.generic_string();
}

bool write_file(std::string_view path, std::string_view data, bool append,
                std::string* error) {
    std::ios::openmode mode = std::ios::binary | std::ios::out;
    mode |= append ? std::ios::app : std::ios::trunc;

    std::ofstream file(std::string(path), mode);
    if (!file.is_open()) {
        if (error) *error = "failed to open " + std::string(path);
        return false;
    }

    file.write(data.data(), static_cast<std::streamsize>(data.size()));
    if (!file.good()) {
        if (error) *error = "short write to " + std::string(path);
        return false;
    }
    return true;
}

double profile_time_seconds() {
    static const auto origin = std::chrono::steady_clock::now();
    const auto now = std::chrono::steady_clock::now();
    return std::chrono::duration<double>(now - origin).count();
}

std::string node_name() {
    static const std::string name = make_node_name();
    return name;
}

std::tm local_time(std::time_t value) {
    static std::mutex mutex;
    std::lock_guard lock(mutex);
    if (std::tm* tm = std::localtime(&value)) {
        return *tm;
    }
    return {};
}

} // namespace skynet::platform
