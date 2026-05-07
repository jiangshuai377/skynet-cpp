-- mongo.lua — MongoDB client driver for skynet-cpp
--
-- Pure Lua implementation using OP_MSG protocol (MongoDB 3.6+).
-- Based on socketchannel for connection management.
--
-- Usage:
--   local mongo = require "skynet.db.mongo"
--   local client = mongo.client { host = "127.0.0.1", port = 27017 }
--   local db = client:getDB("test")
--   local coll = db:getCollection("users")
--   coll:insert({ name = "Alice", age = 30 })
--   local doc = coll:findOne({ name = "Alice" })
--   client:disconnect()

local socketchannel = require "skynet.socketchannel"
local bson = require "bson"

local string = string
local table = table
local setmetatable = setmetatable
local assert = assert
local type = type
local pairs = pairs

local mongo = {}

local OP_MSG = 2013
local request_id = 0

-- ============================================================================
-- Wire protocol
-- ============================================================================

local function gen_id()
    request_id = request_id + 1
    return request_id
end

--- Build an OP_MSG packet.
-- flags: 0 = normal (expect reply), 2 = fire-and-forget
local function op_msg(reqid, flags, bson_doc)
    local payload_type = "\0"  -- Section type 0
    local body = string.pack("<i4", flags) .. payload_type .. bson_doc
    local header = string.pack("<i4i4i4i4",
        16 + #body,     -- message length
        reqid,          -- requestID
        0,              -- responseTo
        OP_MSG          -- opcode
    )
    return header .. body
end

--- Read an OP_MSG response. Returns (request_id, ok, document).
local function read_reply(sock)
    local header = sock:read(4)
    if not header then return nil end
    local msg_len = string.unpack("<i4", header)
    local rest = sock:read(msg_len - 4)
    if not rest then return nil end

    local reqid, resp_to, opcode = string.unpack("<i4i4i4", rest, 1)

    -- OP_MSG: flags(4) + payload_type(1) + bson
    local flags = string.unpack("<i4", rest, 13)
    local payload_type = string.byte(rest, 17)
    assert(payload_type == 0, "unsupported payload type")

    local doc = bson.decode(rest, 18)
    local ok = doc.ok == 1 or doc.ok == true

    return reqid, ok, doc
end

-- ============================================================================
-- Connection management
-- ============================================================================

local client_mt = {}
client_mt.__index = client_mt

local db_mt = {}
db_mt.__index = db_mt

local collection_mt = {}
collection_mt.__index = collection_mt

local cursor_mt = {}
cursor_mt.__index = cursor_mt

-- Response callback for socketchannel (session mode by request_id)
local function mongo_response(self)
    local header = self:read(4)
    if not header then return nil end
    local msg_len = string.unpack("<i4", header)
    local rest = self:read(msg_len - 4)
    if not rest then return nil end

    local reqid, resp_to, opcode = string.unpack("<i4i4i4", rest, 1)
    local flags = string.unpack("<i4", rest, 13)
    local payload_type = string.byte(rest, 17)

    local doc_data = rest:sub(18)
    -- Return: session(=resp_to), ok, data
    return resp_to, true, doc_data
end

-- ============================================================================
-- Client
-- ============================================================================

function mongo.client(conf)
    local self = setmetatable({}, client_mt)
    self.__host = conf.host or "127.0.0.1"
    self.__port = conf.port or 27017

    self.__channel = socketchannel.channel {
        host = self.__host,
        port = self.__port,
        response = mongo_response,
        nodelay = true,
    }
    self.__channel:connect(true)
    return self
end

function client_mt:disconnect()
    self.__channel:close()
end

function client_mt:getDB(name)
    return setmetatable({
        __client = self,
        __name = name,
    }, db_mt)
end

-- Shorthand: client.dbname
client_mt.__index = function(self, key)
    if client_mt[key] then return client_mt[key] end
    return self:getDB(key)
end

-- ============================================================================
-- Database
-- ============================================================================

function db_mt:getCollection(name)
    return setmetatable({
        __db = self,
        __name = name,
        __fullname = self.__name .. "." .. name,
    }, collection_mt)
end

--- Run a database command (ordered keys via varargs: k1, v1, k2, v2, ...)
function db_mt:runCommand(...)
    local client = self.__client
    local reqid = gen_id()
    local args = table.pack(...)
    args[args.n + 1] = "$db"
    args[args.n + 2] = self.__name
    local doc = bson.encode_order(table.unpack(args, 1, args.n + 2))
    local packet = op_msg(reqid, 0, doc)
    local response = client.__channel:request(packet, reqid)
    return bson.decode(response)
end

--- Send a command without expecting a response (fire-and-forget)
function db_mt:sendCommand(...)
    local client = self.__client
    local reqid = gen_id()
    local args = table.pack(...)
    args[args.n + 1] = "$db"
    args[args.n + 2] = self.__name
    local doc = bson.encode_order(table.unpack(args, 1, args.n + 2))
    local packet = op_msg(reqid, 2, doc)
    client.__channel:request(packet)  -- nil session = no wait
end

db_mt.__index = function(self, key)
    if db_mt[key] then return db_mt[key] end
    return self:getCollection(key)
end

-- ============================================================================
-- Collection CRUD
-- ============================================================================

--- Insert a single document. Returns server response.
function collection_mt:insert(doc)
    local db = self.__db
    return db:runCommand(
        "insert", self.__name,
        "documents", { doc },
        "ordered", true
    )
end

--- Insert a single document with safety (returns result or error).
function collection_mt:safe_insert(doc)
    local result = self:insert(doc)
    if result.ok ~= 1 then
        error("insert failed: " .. (result.errmsg or "unknown"))
    end
    return result
end

--- Insert multiple documents.
function collection_mt:batch_insert(docs)
    local db = self.__db
    return db:runCommand(
        "insert", self.__name,
        "documents", docs,
        "ordered", true
    )
end

--- Find a single document.
function collection_mt:findOne(query, projection)
    local db = self.__db
    local args = {
        "find", self.__name,
        "filter", query or {},
        "limit", 1,
        "singleBatch", true,
    }
    if projection then
        args[#args + 1] = "projection"
        args[#args + 1] = projection
    end
    local result = db:runCommand(table.unpack(args))
    if result.cursor and result.cursor.firstBatch and #result.cursor.firstBatch > 0 then
        return result.cursor.firstBatch[1]
    end
    return nil
end

--- Find documents, returns a cursor.
function collection_mt:find(query, projection)
    local c = setmetatable({
        __collection = self,
        __query = query or {},
        __projection = projection,
        __cursor_id = nil,
        __batch = nil,
        __batch_idx = 0,
        __started = false,
        __finished = false,
        __sort = nil,
        __skip = nil,
        __limit = nil,
    }, cursor_mt)
    return c
end

--- Update documents.
function collection_mt:update(query, update, upsert, multi)
    local db = self.__db
    local upd = {
        q = query,
        u = update,
    }
    if upsert then upd.upsert = true end
    if multi then upd.multi = true end
    return db:runCommand(
        "update", self.__name,
        "updates", { upd }
    )
end

--- Delete documents.
function collection_mt:delete(query, single)
    local db = self.__db
    local del = {
        q = query or {},
        limit = single and 1 or 0,
    }
    return db:runCommand(
        "delete", self.__name,
        "deletes", { del }
    )
end

--- FindAndModify.
function collection_mt:findAndModify(doc)
    local db = self.__db
    local args = { "findAndModify", self.__name }
    for k, v in pairs(doc) do
        args[#args + 1] = k
        args[#args + 1] = v
    end
    return db:runCommand(table.unpack(args))
end

--- Create an index.
function collection_mt:createIndex(keys, options)
    local db = self.__db
    local index = { key = keys }
    if options then
        for k, v in pairs(options) do
            index[k] = v
        end
    end
    if not index.name then
        -- Generate index name
        local parts = {}
        for k, v in pairs(keys) do
            parts[#parts + 1] = k .. "_" .. tostring(v)
        end
        index.name = table.concat(parts, "_")
    end
    return db:runCommand(
        "createIndexes", self.__name,
        "indexes", { index }
    )
end

--- Drop this collection.
function collection_mt:drop()
    return self.__db:runCommand("drop", self.__name)
end

--- Count documents matching query.
function collection_mt:count(query)
    local result = self.__db:runCommand(
        "count", self.__name,
        "query", query or {}
    )
    return result.n or 0
end

--- Aggregate pipeline.
function collection_mt:aggregate(pipeline)
    local result = self.__db:runCommand(
        "aggregate", self.__name,
        "pipeline", pipeline,
        "cursor", {}
    )
    -- Return results from firstBatch
    if result.cursor and result.cursor.firstBatch then
        return result.cursor.firstBatch
    end
    return {}
end

-- ============================================================================
-- Cursor
-- ============================================================================

function cursor_mt:sort(s)
    self.__sort = s
    return self
end

function cursor_mt:skip(n)
    self.__skip = n
    return self
end

function cursor_mt:limit(n)
    self.__limit = n
    return self
end

local function cursor_start(self)
    if self.__started then return end
    self.__started = true

    local coll = self.__collection
    local db = coll.__db
    local args = {
        "find", coll.__name,
        "filter", self.__query,
    }
    if self.__projection then
        args[#args + 1] = "projection"
        args[#args + 1] = self.__projection
    end
    if self.__sort then
        args[#args + 1] = "sort"
        args[#args + 1] = self.__sort
    end
    if self.__skip then
        args[#args + 1] = "skip"
        args[#args + 1] = self.__skip
    end
    if self.__limit then
        args[#args + 1] = "limit"
        args[#args + 1] = self.__limit
    end

    local result = db:runCommand(table.unpack(args))
    if result.cursor then
        self.__batch = result.cursor.firstBatch or {}
        self.__cursor_id = result.cursor.id or 0
    else
        self.__batch = {}
        self.__cursor_id = 0
    end
    self.__batch_idx = 0
end

function cursor_mt:hasNext()
    cursor_start(self)

    if self.__batch_idx < #self.__batch then
        return true
    end

    if self.__cursor_id == 0 then
        self.__finished = true
        return false
    end

    -- Fetch next batch via getMore
    local coll = self.__collection
    local db = coll.__db
    local result = db:runCommand(
        "getMore", bson.int64(self.__cursor_id),
        "collection", coll.__name
    )
    if result.cursor then
        self.__batch = result.cursor.nextBatch or {}
        self.__cursor_id = result.cursor.id or 0
    else
        self.__batch = {}
        self.__cursor_id = 0
    end
    self.__batch_idx = 0

    if #self.__batch == 0 then
        self.__finished = true
        return false
    end
    return true
end

function cursor_mt:next()
    if not self:hasNext() then return nil end
    self.__batch_idx = self.__batch_idx + 1
    return self.__batch[self.__batch_idx]
end

function cursor_mt:close()
    if self.__cursor_id and self.__cursor_id ~= 0 then
        local coll = self.__collection
        local db = coll.__db
        pcall(function()
            db:runCommand(
                "killCursors", coll.__name,
                "cursors", { bson.int64(self.__cursor_id) }
            )
        end)
        self.__cursor_id = 0
    end
end

--- Collect all cursor results into a table.
function cursor_mt:toArray()
    local result = {}
    while self:hasNext() do
        result[#result + 1] = self:next()
    end
    return result
end

function mongo._selftest()
    local packet = op_msg(11, 0, bson.encode { ok = 1 })
    assert(#packet > 16, "mongo op_msg selftest failed")
    local sock = {
        parts = {
            string.pack("<i4", 16 + 5 + #bson.encode { ok = 1 }),
            string.pack("<i4i4i4", 12, 11, OP_MSG) .. string.pack("<i4B", 0, 0) .. bson.encode { ok = 1 },
        },
        read = function(self)
            return table.remove(self.parts, 1)
        end,
    }
    local reqid, ok, doc = read_reply(sock)
    assert(reqid == 12 and ok == true and doc.ok == 1, "mongo read_reply selftest failed")

    local client = setmetatable({ __channel = { request = function() return bson.encode { ok = 1 } end } }, client_mt)
    assert(client.anydb.__name == "anydb", "mongo client index selftest failed")
    local db = client:getDB("stress")
    assert(db.anycoll.__name == "anycoll", "mongo db index selftest failed")
    local coll = db:getCollection("items")
    local empty = setmetatable({ __collection = coll, __query = {}, __batch = {}, __batch_idx = 0,
        __cursor_id = 0, __started = true }, cursor_mt)
    assert(empty:hasNext() == false and empty:next() == nil, "mongo empty cursor selftest failed")
    return true
end

return mongo
