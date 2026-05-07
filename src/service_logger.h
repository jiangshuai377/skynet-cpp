#pragma once

#include "platform.h"
#include "skynet.h"

#include <chrono>
#include <cstdio>
#include <ctime>
#include <fstream>
#include <string>

namespace skynet {

// ============================================================================
// ServiceLogger -- built-in logger actor
//
// Receives PTYPE_TEXT and PTYPE_ERROR messages, formats with timestamp
// and source handle, writes to stdout and optionally to a log file.
// ============================================================================

class ServiceLogger : public Actor {
    std::ofstream file_;

public:
    explicit ServiceLogger(const std::string& logfile = "") {
        if (!logfile.empty()) {
            file_.open(logfile, std::ios::out | std::ios::app);
        }
    }

protected:
    void on_init(std::string_view) override {}

    void on_message(const Message& msg) override {
        if (msg.type != PTYPE_TEXT && msg.type != PTYPE_ERROR)
            return;

        const char* tag = (msg.type == PTYPE_ERROR) ? "ERROR" : "INFO";
        std::string text;
        try {
            text = msg.get<std::string>();
        } catch (...) {
            return;
        }

        // Timestamp
        auto now  = std::chrono::system_clock::now();
        auto time = std::chrono::system_clock::to_time_t(now);
        auto ms   = std::chrono::duration_cast<std::chrono::milliseconds>(
                        now.time_since_epoch()) % 1000;
        std::tm tm_buf = platform::local_time(time);

        char ts[32];
        std::snprintf(ts, sizeof(ts), "%02d:%02d:%02d.%03d",
                      tm_buf.tm_hour, tm_buf.tm_min, tm_buf.tm_sec,
                      static_cast<int>(ms.count()));

        char line[1024];
        int n = std::snprintf(line, sizeof(line),
                              "[%s][%08x][%s] %s\n",
                              ts, msg.source, tag, text.c_str());
        if (n < 0) return;
        size_t len = n < static_cast<int>(sizeof(line))
                         ? static_cast<size_t>(n)
                         : sizeof(line) - 1;

        std::fwrite(line, 1, len, stdout);
        std::fflush(stdout);

        if (file_.is_open()) {
            file_.write(line, static_cast<std::streamsize>(len));
            file_.flush();
        }
    }

    void on_destroy() override {
        if (file_.is_open()) file_.close();
    }
};

} // namespace skynet
