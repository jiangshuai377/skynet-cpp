-- bson.lua — Pure Lua BSON encoder/decoder
--
-- Supports basic BSON types: double, string, document, array, binary,
-- objectid, boolean, datetime, null, int32, int64.

local string = string
local table = table
local math = math
local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local error = error
local setmetatable = setmetatable

-- Use os.time if available, otherwise fallback to skynet time
local function get_time()
    if os and os.time then
        return os.time()
    end
    -- skynet environment: lazy require
    local ok, skynet = pcall(require, "skynet")
    if ok then
        local c = require "skynet.core"
        local starttime = c.starttime()
        local now = c.now()
        return math.floor(now / 100 + starttime)
    end
    return 0
end

local bson = {}

-- BSON type tags
local BSON_DOUBLE    = 0x01
local BSON_STRING    = 0x02
local BSON_DOCUMENT  = 0x03
local BSON_ARRAY     = 0x04
local BSON_BINARY    = 0x05
local BSON_OBJECTID  = 0x07
local BSON_BOOLEAN   = 0x08
local BSON_DATETIME  = 0x09
local BSON_NULL      = 0x0A
local BSON_INT32     = 0x10
local BSON_INT64     = 0x12
local BSON_MINKEY    = 0xFF
local BSON_MAXKEY    = 0x7F

-- Sentinel values
bson.null = setmetatable({}, { __tostring = function() return "bson.null" end })
bson.minkey = setmetatable({}, { __tostring = function() return "bson.minkey" end })
bson.maxkey = setmetatable({}, { __tostring = function() return "bson.maxkey" end })

-- Int64 wrapper
local int64_mt = {
    __tostring = function(self) return tostring(self.value) end,
    __eq = function(a, b) return a.value == b.value end,
}

function bson.int64(v)
    return setmetatable({ value = v, __bson_type = "int64" }, int64_mt)
end

-- ObjectId wrapper
local objectid_mt = {
    __tostring = function(self)
        return self.hex
    end,
    __eq = function(a, b) return a.hex == b.hex end,
}

local objectid_counter = 0
function bson.objectid(hex)
    if hex then
        assert(#hex == 24, "ObjectId must be 24 hex chars")
        local bytes = hex:gsub("..", function(cc)
            return string.char(tonumber(cc, 16))
        end)
        return setmetatable({ hex = hex, bytes = bytes, __bson_type = "objectid" }, objectid_mt)
    end
    -- Generate a new ObjectId
    local t = get_time()
    objectid_counter = objectid_counter + 1
    local bytes = string.pack(">I4", t) ..
                  string.rep("\0", 5) ..  -- machine + pid placeholder
                  string.pack(">I3", objectid_counter % 0xFFFFFF)
    local h = bytes:gsub(".", function(c) return string.format("%02x", string.byte(c)) end)
    return setmetatable({ hex = h, bytes = bytes, __bson_type = "objectid" }, objectid_mt)
end

-- ============================================================================
-- BSON Encoding
-- ============================================================================

local function encode_cstring(s)
    return s .. "\0"
end

local function encode_element(key, value)
    local t = type(value)

    if t == "number" then
        if math.tointeger(value) then
            local iv = math.tointeger(value)
            if iv >= -2147483648 and iv <= 2147483647 then
                return string.char(BSON_INT32) .. encode_cstring(key) .. string.pack("<i4", iv)
            else
                return string.char(BSON_INT64) .. encode_cstring(key) .. string.pack("<i8", iv)
            end
        else
            return string.char(BSON_DOUBLE) .. encode_cstring(key) .. string.pack("<d", value)
        end
    elseif t == "string" then
        return string.char(BSON_STRING) .. encode_cstring(key) ..
               string.pack("<i4", #value + 1) .. value .. "\0"
    elseif t == "boolean" then
        return string.char(BSON_BOOLEAN) .. encode_cstring(key) ..
               string.char(value and 1 or 0)
    elseif t == "table" then
        if value == bson.null then
            return string.char(BSON_NULL) .. encode_cstring(key)
        elseif value == bson.minkey then
            return string.char(BSON_MINKEY) .. encode_cstring(key)
        elseif value == bson.maxkey then
            return string.char(BSON_MAXKEY) .. encode_cstring(key)
        elseif value.__bson_type == "int64" then
            return string.char(BSON_INT64) .. encode_cstring(key) ..
                   string.pack("<i8", value.value)
        elseif value.__bson_type == "objectid" then
            return string.char(BSON_OBJECTID) .. encode_cstring(key) .. value.bytes
        elseif #value > 0 or next(value) == nil then
            -- Check if it looks like an array (sequential integer keys from 1)
            local is_array = true
            local n = #value
            for k in pairs(value) do
                if type(k) ~= "number" or k < 1 or k > n or k ~= math.floor(k) then
                    if k == "n" then -- table.pack sets n
                    else
                        is_array = false
                        break
                    end
                end
            end
            if is_array and n > 0 then
                -- Encode as BSON array
                local body = ""
                for i = 1, n do
                    body = body .. encode_element(tostring(i - 1), value[i])
                end
                body = body .. "\0"
                return string.char(BSON_ARRAY) .. encode_cstring(key) ..
                       string.pack("<i4", #body + 4) .. body
            else
                -- Encode as BSON document
                return string.char(BSON_DOCUMENT) .. encode_cstring(key) .. bson.encode(value)
            end
        else
            return string.char(BSON_DOCUMENT) .. encode_cstring(key) .. bson.encode(value)
        end
    elseif t == "nil" then
        return string.char(BSON_NULL) .. encode_cstring(key)
    else
        error("unsupported BSON type: " .. t)
    end
end

function bson.encode(doc)
    local body = ""
    for k, v in pairs(doc) do
        body = body .. encode_element(tostring(k), v)
    end
    body = body .. "\0"
    return string.pack("<i4", #body + 4) .. body
end

--- Encode with guaranteed key order (varargs: k1, v1, k2, v2, ...)
function bson.encode_order(...)
    local args = { ... }
    local body = ""
    for i = 1, #args, 2 do
        local k = args[i]
        local v = args[i + 1]
        body = body .. encode_element(tostring(k), v)
    end
    body = body .. "\0"
    return string.pack("<i4", #body + 4) .. body
end

-- ============================================================================
-- BSON Decoding
-- ============================================================================

local function decode_cstring(data, pos)
    local e = data:find("\0", pos, true)
    if not e then error("unterminated cstring") end
    return data:sub(pos, e - 1), e + 1
end

local decode_element  -- forward declare

local function decode_document(data, pos)
    local doc_len = string.unpack("<i4", data, pos)
    local doc = {}
    local end_pos = pos + doc_len
    pos = pos + 4
    while pos < end_pos - 1 do
        local key, value
        key, value, pos = decode_element(data, pos)
        doc[key] = value
    end
    return doc, end_pos
end

local function decode_array(data, pos)
    local arr_len = string.unpack("<i4", data, pos)
    local arr = {}
    local end_pos = pos + arr_len
    pos = pos + 4
    while pos < end_pos - 1 do
        local key, value
        key, value, pos = decode_element(data, pos)
        arr[tonumber(key) + 1] = value
    end
    return arr, end_pos
end

decode_element = function(data, pos)
    local type_byte = string.byte(data, pos)
    pos = pos + 1
    local key
    key, pos = decode_cstring(data, pos)

    if type_byte == BSON_DOUBLE then
        local v
        v, pos = string.unpack("<d", data, pos)
        return key, v, pos
    elseif type_byte == BSON_STRING then
        local len
        len, pos = string.unpack("<i4", data, pos)
        local v = data:sub(pos, pos + len - 2)  -- exclude null terminator
        return key, v, pos + len
    elseif type_byte == BSON_DOCUMENT then
        local v
        v, pos = decode_document(data, pos)
        return key, v, pos
    elseif type_byte == BSON_ARRAY then
        local v
        v, pos = decode_array(data, pos)
        return key, v, pos
    elseif type_byte == BSON_BINARY then
        local len
        len, pos = string.unpack("<i4", data, pos)
        local subtype = string.byte(data, pos)
        local v = data:sub(pos + 1, pos + len)
        return key, v, pos + 1 + len
    elseif type_byte == BSON_OBJECTID then
        local bytes = data:sub(pos, pos + 11)
        local hex = bytes:gsub(".", function(c) return string.format("%02x", string.byte(c)) end)
        return key, bson.objectid(hex), pos + 12
    elseif type_byte == BSON_BOOLEAN then
        local v = string.byte(data, pos) ~= 0
        return key, v, pos + 1
    elseif type_byte == BSON_DATETIME then
        local v
        v, pos = string.unpack("<i8", data, pos)
        return key, v, pos
    elseif type_byte == BSON_NULL then
        return key, bson.null, pos
    elseif type_byte == BSON_INT32 then
        local v
        v, pos = string.unpack("<i4", data, pos)
        return key, v, pos
    elseif type_byte == BSON_INT64 then
        local v
        v, pos = string.unpack("<i8", data, pos)
        return key, v, pos
    elseif type_byte == BSON_MINKEY then
        return key, bson.minkey, pos
    elseif type_byte == BSON_MAXKEY then
        return key, bson.maxkey, pos
    else
        error(string.format("unsupported BSON type: 0x%02x", type_byte))
    end
end

function bson.decode(data, pos)
    pos = pos or 1
    return decode_document(data, pos)
end

return bson
