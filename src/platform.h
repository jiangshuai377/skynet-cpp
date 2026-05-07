#pragma once

#include <ctime>
#include <string>
#include <string_view>

namespace skynet::platform {

std::string getenv_string(std::string_view name);

std::string current_path();

bool write_file(std::string_view path, std::string_view data, bool append,
                std::string* error = nullptr);

double profile_time_seconds();

std::string node_name();

std::tm local_time(std::time_t value);

} // namespace skynet::platform
