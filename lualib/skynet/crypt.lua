-- crypt.lua — Minimal cryptographic functions for skynet-cpp
--
-- Pure Lua SHA1 implementation (no external C deps).
-- Sufficient for MySQL authentication.

local string = string
local math = math
local table = table

local crypt = {}

-- SHA1 implementation (pure Lua, using Lua 5.3+ integer ops)
local function uint32(n)
    return n & 0xFFFFFFFF
end

local function rotl(x, n)
    x = uint32(x)
    return uint32((x << n) | (x >> (32 - n)))
end

function crypt.sha1(msg)
    -- Pre-processing
    local len = #msg
    local bit_len = len * 8

    -- Append bit '1' (0x80 byte)
    msg = msg .. "\x80"

    -- Append zeros until message length ≡ 448 (mod 512) bits = 56 (mod 64) bytes
    local pad_len = (56 - (#msg % 64)) % 64
    msg = msg .. string.rep("\0", pad_len)

    -- Append original length in bits as 64-bit big-endian
    msg = msg .. string.pack(">I8", bit_len)

    -- Initialize hash values
    local h0 = 0x67452301
    local h1 = 0xEFCDAB89
    local h2 = 0x98BADCFE
    local h3 = 0x10325476
    local h4 = 0xC3D2E1F0

    -- Process each 512-bit (64-byte) block
    for i = 1, #msg, 64 do
        local w = {}
        for j = 0, 15 do
            w[j] = string.unpack(">I4", msg, i + j * 4)
        end
        for j = 16, 79 do
            w[j] = rotl(w[j-3] ~ w[j-8] ~ w[j-14] ~ w[j-16], 1)
        end

        local a, b, c, d, e = h0, h1, h2, h3, h4

        for j = 0, 79 do
            local f, k
            if j <= 19 then
                f = (b & c) | ((~b) & d)
                k = 0x5A827999
            elseif j <= 39 then
                f = b ~ c ~ d
                k = 0x6ED9EBA1
            elseif j <= 59 then
                f = (b & c) | (b & d) | (c & d)
                k = 0x8F1BBCDC
            else
                f = b ~ c ~ d
                k = 0xCA62C1D6
            end

            local temp = uint32(rotl(a, 5) + f + e + k + w[j])
            e = d
            d = c
            c = rotl(b, 30)
            b = a
            a = temp
        end

        h0 = uint32(h0 + a)
        h1 = uint32(h1 + b)
        h2 = uint32(h2 + c)
        h3 = uint32(h3 + d)
        h4 = uint32(h4 + e)
    end

    return string.pack(">I4I4I4I4I4", h0, h1, h2, h3, h4)
end

-- HMAC-SHA1
function crypt.hmac_sha1(key, msg)
    if #key > 64 then
        key = crypt.sha1(key)
    end
    if #key < 64 then
        key = key .. string.rep("\0", 64 - #key)
    end

    local o_key_pad = {}
    local i_key_pad = {}
    for i = 1, 64 do
        local kb = string.byte(key, i)
        o_key_pad[i] = string.char(kb ~ 0x5c)
        i_key_pad[i] = string.char(kb ~ 0x36)
    end

    local opad = table.concat(o_key_pad)
    local ipad = table.concat(i_key_pad)

    return crypt.sha1(opad .. crypt.sha1(ipad .. msg))
end

-- Base64 encode/decode
local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function crypt.base64encode(data)
    local result = {}
    local len = #data
    local i = 1
    while i <= len do
        local a = string.byte(data, i) or 0
        local b = (i + 1 <= len) and string.byte(data, i + 1) or 0
        local c = (i + 2 <= len) and string.byte(data, i + 2) or 0
        local n = (a << 16) | (b << 8) | c

        result[#result + 1] = b64chars:sub((n >> 18) + 1, (n >> 18) + 1)
        result[#result + 1] = b64chars:sub(((n >> 12) & 63) + 1, ((n >> 12) & 63) + 1)
        if i + 1 <= len then
            result[#result + 1] = b64chars:sub(((n >> 6) & 63) + 1, ((n >> 6) & 63) + 1)
        else
            result[#result + 1] = "="
        end
        if i + 2 <= len then
            result[#result + 1] = b64chars:sub((n & 63) + 1, (n & 63) + 1)
        else
            result[#result + 1] = "="
        end
        i = i + 3
    end
    return table.concat(result)
end

local b64lookup = {}
for i = 1, #b64chars do
    b64lookup[string.byte(b64chars, i)] = i - 1
end

function crypt.base64decode(data)
    data = data:gsub("[^%w+/=]", "")
    local result = {}
    local i = 1
    while i <= #data do
        local a = b64lookup[string.byte(data, i)] or 0
        local b = b64lookup[string.byte(data, i + 1)] or 0
        local c = b64lookup[string.byte(data, i + 2)] or 0
        local d = b64lookup[string.byte(data, i + 3)] or 0
        local n = (a << 18) | (b << 12) | (c << 6) | d

        result[#result + 1] = string.char((n >> 16) & 0xFF)
        if data:sub(i + 2, i + 2) ~= "=" then
            result[#result + 1] = string.char((n >> 8) & 0xFF)
        end
        if data:sub(i + 3, i + 3) ~= "=" then
            result[#result + 1] = string.char(n & 0xFF)
        end
        i = i + 4
    end
    return table.concat(result)
end

-- Hex encode/decode
function crypt.hexencode(data)
    return (data:gsub(".", function(c) return string.format("%02x", string.byte(c)) end))
end

function crypt.hexdecode(data)
    return (data:gsub("..", function(cc) return string.char(tonumber(cc, 16)) end))
end

return crypt
