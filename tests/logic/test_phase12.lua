-- test_phase12.lua — Phase 12 Verification
--
-- Tests:
--   1. Message Queue (skynet.queue)
--   2. ShareData
--   3. Multicast
--   4. BSON encode/decode
--   5. SHA1 / crypt
--   6. Redis RESP protocol construction (offline)
--   7. MySQL packet helpers (offline)

local skynet = require "skynet"

skynet.start(function()
    skynet.error("[test_phase12] === Phase 12 Verification ===")

    -- ========================================================================
    -- Test 1: Message Queue (skynet.queue)
    -- ========================================================================
    skynet.error("[test_phase12] --- Test 1: Message Queue ---")
    do
        local queue = require "skynet.queue"
        local q = queue()
        local order = {}

        -- Sequential execution test
        q(function()
            table.insert(order, 1)
        end)
        q(function()
            table.insert(order, 2)
        end)
        q(function()
            table.insert(order, 3)
        end)
        assert(order[1] == 1 and order[2] == 2 and order[3] == 3,
            "queue should execute in order")
        skynet.error("[test_phase12] PASS: queue sequential execution")

        -- Reentrant test
        local reentrant_ok = false
        q(function()
            q(function()
                reentrant_ok = true
            end)
        end)
        assert(reentrant_ok, "queue should support reentrant calls")
        skynet.error("[test_phase12] PASS: queue reentrant")
    end

    -- ========================================================================
    -- Test 2: ShareData
    -- ========================================================================
    skynet.error("[test_phase12] --- Test 2: ShareData ---")
    do
        local sharedata = require "sharedata"

        -- Create shared data
        sharedata.new("test_config", { fps = 60, name = "skynet-cpp", debug = true })
        skynet.error("[test_phase12] PASS: sharedata.new works")

        -- Query shared data
        local cfg = sharedata.query("test_config")
        assert(cfg.fps == 60, "fps mismatch: " .. tostring(cfg.fps))
        assert(cfg.name == "skynet-cpp", "name mismatch")
        assert(cfg.debug == true, "debug mismatch")
        skynet.error("[test_phase12] PASS: sharedata.query works")

        -- Update shared data
        sharedata.update("test_config", { fps = 30, name = "updated", debug = false })
        skynet.error("[test_phase12] PASS: sharedata.update works")

        -- Delete shared data
        sharedata.delete("test_config")
        skynet.error("[test_phase12] PASS: sharedata.delete works")
    end

    -- ========================================================================
    -- Test 3: Multicast
    -- ========================================================================
    skynet.error("[test_phase12] --- Test 3: Multicast ---")
    do
        local multicast = require "skynet.multicast"

        -- Create channel
        local mc = multicast.new()
        assert(mc.channel and mc.channel > 0, "channel ID should be positive")
        skynet.error("[test_phase12] PASS: multicast.new works, channel=" .. mc.channel)

        -- Subscribe
        mc:subscribe()
        skynet.error("[test_phase12] PASS: multicast.subscribe works")

        -- Unsubscribe
        mc:unsubscribe()
        skynet.error("[test_phase12] PASS: multicast.unsubscribe works")

        -- Delete channel
        mc:delete()
        skynet.error("[test_phase12] PASS: multicast.delete works")
    end

    -- ========================================================================
    -- Test 4: BSON encode/decode
    -- ========================================================================
    skynet.error("[test_phase12] --- Test 4: BSON ---")
    do
        local bson = require "bson"

        -- Simple document
        local doc = { name = "Alice", age = 30, active = true }
        local encoded = bson.encode(doc)
        assert(type(encoded) == "string", "encode should return string")
        assert(#encoded > 0, "encoded should not be empty")

        local decoded = bson.decode(encoded)
        assert(decoded.name == "Alice", "name mismatch")
        assert(decoded.age == 30, "age mismatch: " .. tostring(decoded.age))
        assert(decoded.active == true, "active mismatch")
        skynet.error("[test_phase12] PASS: BSON basic encode/decode")

        -- Nested document
        local nested = { user = { name = "Bob", scores = { 1, 2, 3 } } }
        encoded = bson.encode(nested)
        decoded = bson.decode(encoded)
        assert(decoded.user.name == "Bob", "nested name mismatch")
        assert(decoded.user.scores[1] == 1, "array[1] mismatch")
        assert(decoded.user.scores[2] == 2, "array[2] mismatch")
        assert(decoded.user.scores[3] == 3, "array[3] mismatch")
        skynet.error("[test_phase12] PASS: BSON nested + array")

        -- Special types
        local oid = bson.objectid()
        assert(#oid.hex == 24, "objectid hex should be 24 chars")
        skynet.error("[test_phase12] PASS: BSON objectid = " .. oid.hex)

        local i64 = bson.int64(123456789012345)
        local spec = { big = i64, nothing = bson.null }
        encoded = bson.encode(spec)
        decoded = bson.decode(encoded)
        assert(decoded.big == 123456789012345, "int64 mismatch: " .. tostring(decoded.big))
        assert(decoded.nothing == bson.null, "null mismatch")
        skynet.error("[test_phase12] PASS: BSON int64 + null")

        -- encode_order
        encoded = bson.encode_order("cmd", "find", "ns", "test.coll", "limit", 10)
        decoded = bson.decode(encoded)
        assert(decoded.cmd == "find", "encode_order cmd mismatch")
        assert(decoded.ns == "test.coll", "encode_order ns mismatch")
        assert(decoded.limit == 10, "encode_order limit mismatch")
        skynet.error("[test_phase12] PASS: BSON encode_order")
    end

    -- ========================================================================
    -- Test 5: SHA1 / Crypt
    -- ========================================================================
    skynet.error("[test_phase12] --- Test 5: Crypt ---")
    do
        local crypt = require "skynet.crypt"

        -- SHA1 test vectors
        local hash1 = crypt.sha1("")
        local hex1 = crypt.hexencode(hash1)
        assert(hex1 == "da39a3ee5e6b4b0d3255bfef95601890afd80709",
            "SHA1('') mismatch: " .. hex1)
        skynet.error("[test_phase12] PASS: SHA1 empty string")

        local hash2 = crypt.sha1("abc")
        local hex2 = crypt.hexencode(hash2)
        assert(hex2 == "a9993e364706816aba3e25717850c26c9cd0d89d",
            "SHA1('abc') mismatch: " .. hex2)
        skynet.error("[test_phase12] PASS: SHA1 'abc'")

        -- Base64
        local b64 = crypt.base64encode("Hello, World!")
        assert(b64 == "SGVsbG8sIFdvcmxkIQ==", "base64 encode mismatch: " .. b64)
        local decoded = crypt.base64decode(b64)
        assert(decoded == "Hello, World!", "base64 decode mismatch")
        skynet.error("[test_phase12] PASS: Base64 encode/decode")

        -- Hex
        local h = crypt.hexencode("\x01\x02\xff")
        assert(h == "0102ff", "hex encode mismatch: " .. h)
        local d = crypt.hexdecode(h)
        assert(d == "\x01\x02\xff", "hex decode mismatch")
        skynet.error("[test_phase12] PASS: Hex encode/decode")
    end

    -- ========================================================================
    -- Test 6: Redis RESP protocol (offline)
    -- ========================================================================
    skynet.error("[test_phase12] --- Test 6: Redis RESP (offline) ---")
    do
        -- Just verify the module loads without error
        -- (actual Redis connection requires a running server)
        local ok, redis = pcall(require, "skynet.db.redis")
        assert(ok, "redis module should load: " .. tostring(redis))
        assert(type(redis.connect) == "function", "redis.connect should be function")
        assert(type(redis.watch) == "function", "redis.watch should be function")
        skynet.error("[test_phase12] PASS: Redis module loads")
    end

    -- ========================================================================
    -- Test 7: MySQL module (offline)
    -- ========================================================================
    skynet.error("[test_phase12] --- Test 7: MySQL (offline) ---")
    do
        local ok, mysql = pcall(require, "skynet.db.mysql")
        assert(ok, "mysql module should load: " .. tostring(mysql))
        assert(type(mysql.connect) == "function", "mysql.connect should be function")
        assert(type(mysql.query) == "function", "mysql.query should be function")
        skynet.error("[test_phase12] PASS: MySQL module loads")
    end

    -- ========================================================================
    -- Test 8: MongoDB module (offline)
    -- ========================================================================
    skynet.error("[test_phase12] --- Test 8: MongoDB (offline) ---")
    do
        local ok, mongod = pcall(require, "skynet.db.mongo")
        assert(ok, "mongo module should load: " .. tostring(mongod))
        assert(type(mongod.client) == "function", "mongo.client should be function")
        skynet.error("[test_phase12] PASS: MongoDB module loads")
    end

    skynet.error("[test_phase12] === All Phase 12 tests completed ===")
end)
