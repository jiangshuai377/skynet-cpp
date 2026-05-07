#pragma once

// skynet_json.h -- Thin C++ convenience wrapper over RapidJSON
//
// Provides simple encode/decode helpers for use in C++ actors and services.
// For Lua services, use `require "rapidjson"` instead.
//
// Usage:
//   #include "skynet_json.h"
//
//   // Parse JSON string
//   auto doc = skynet::json::parse(R"({"key":"value","num":42})");
//   std::string val = doc["key"].GetString();
//   int num = doc["num"].GetInt();
//
//   // Build and serialize JSON
//   std::string out = skynet::json::encode({...});  // use RapidJSON API directly
//
//   // Or use the stringify helper
//   rapidjson::Document d;
//   d.SetObject();
//   auto& alloc = d.GetAllocator();
//   d.AddMember("name", "test", alloc);
//   d.AddMember("value", 42, alloc);
//   std::string json_str = skynet::json::stringify(d);
//   std::string pretty   = skynet::json::stringify(d, true);

#include <string>
#include <string_view>
#include <stdexcept>

#include <rapidjson/document.h>
#include <rapidjson/writer.h>
#include <rapidjson/prettywriter.h>
#include <rapidjson/stringbuffer.h>
#include <rapidjson/error/en.h>

namespace skynet {
namespace json {

/// Parse a JSON string into a RapidJSON Document.
/// Throws std::runtime_error on parse failure.
inline rapidjson::Document parse(std::string_view json_str) {
    rapidjson::Document doc;
    doc.Parse(json_str.data(), json_str.size());
    if (doc.HasParseError()) {
        throw std::runtime_error(
            std::string("JSON parse error at offset ") +
            std::to_string(doc.GetErrorOffset()) + ": " +
            rapidjson::GetParseError_En(doc.GetParseError()));
    }
    return doc;
}

/// Stringify a RapidJSON Value (Document, Object, Array, etc.) to JSON string.
/// Set pretty=true for indented output.
inline std::string stringify(const rapidjson::Value& value, bool pretty = false) {
    rapidjson::StringBuffer buffer;
    if (pretty) {
        rapidjson::PrettyWriter<rapidjson::StringBuffer> writer(buffer);
        value.Accept(writer);
    } else {
        rapidjson::Writer<rapidjson::StringBuffer> writer(buffer);
        value.Accept(writer);
    }
    return {buffer.GetString(), buffer.GetSize()};
}

} // namespace json
} // namespace skynet
