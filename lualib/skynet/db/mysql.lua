-- mysql.lua — MySQL client driver for skynet-cpp
--
-- Based on lua-resty-mysql, modified for skynet socketchannel.
-- Supports query, prepare, execute, and multiple result sets.
--
-- Usage:
--   local mysql = require "skynet.db.mysql"
--   local db = mysql.connect {
--       host = "127.0.0.1", port = 3306,
--       user = "root", password = "pass",
--       database = "test",
--   }
--   local res = db:query("SELECT * FROM users")
--   db:disconnect()

local socketchannel = require "skynet.socketchannel"
local crypt = require "skynet.crypt"

local sub = string.sub
local strgsub = string.gsub
local strformat = string.format
local strbyte = string.byte
local strchar = string.char
local strrep = string.rep
local strunpack = string.unpack
local strpack = string.pack
local sha1 = crypt.sha1
local setmetatable = setmetatable
local error = error
local tonumber = tonumber
local tointeger = math.tointeger

local _M = { _VERSION = "0.14" }

-- Charset map (MySQL charset ID)
local CHARSET_MAP = {
    _default  = 0,
    big5      = 1,
    latin1    = 8,
    ascii     = 11,
    gb2312    = 24,
    gbk       = 28,
    utf8      = 33,
    utf8mb4   = 45,
    binary    = 63,
}

-- MySQL command constants
local COM_QUERY         = "\x03"
local COM_PING          = "\x0e"
local COM_STMT_PREPARE  = "\x16"
local COM_STMT_EXECUTE  = "\x17"
local COM_STMT_CLOSE    = "\x19"
local COM_STMT_RESET    = "\x1a"
local CURSOR_TYPE_NO_CURSOR = 0x00
local SERVER_MORE_RESULTS_EXISTS = 8

local mt = { __index = _M }

-- Field type converters (text protocol)
local converters = {}
for i = 0x01, 0x05 do
    converters[i] = tonumber
end
converters[0x08] = tonumber  -- long long
converters[0x09] = tonumber  -- int24
converters[0x0d] = tonumber  -- year
converters[0xf6] = tonumber  -- newdecimal

-- ============================================================================
-- Wire protocol helpers
-- ============================================================================

local function _get_byte2(data, i)
    return strunpack("<I2", data, i)
end

local function _get_byte3(data, i)
    return strunpack("<I3", data, i)
end

local function _get_byte4(data, i)
    return strunpack("<I4", data, i)
end

local function _get_int1(data, i, is_signed)
    if not is_signed then return strunpack("<I1", data, i) end
    return strunpack("<i1", data, i)
end

local function _get_int2(data, i, is_signed)
    if not is_signed then return strunpack("<I2", data, i) end
    return strunpack("<i2", data, i)
end

local function _get_int3(data, i, is_signed)
    if not is_signed then return strunpack("<I3", data, i) end
    return strunpack("<i3", data, i)
end

local function _get_int4(data, i, is_signed)
    if not is_signed then return strunpack("<I4", data, i) end
    return strunpack("<i4", data, i)
end

local function _get_int8(data, i, is_signed)
    if not is_signed then return strunpack("<I8", data, i) end
    return strunpack("<i8", data, i)
end

local function _get_float(data, i)
    return strunpack("<f", data, i)
end

local function _get_double(data, i)
    return strunpack("<d", data, i)
end

local function _set_byte2(n)
    return strpack("<I2", n)
end

local function _set_int8(n)
    return strpack("<i8", n)
end

local function _set_double(n)
    return strpack("<d", n)
end

local function _from_cstring(data, i)
    return strunpack("z", data, i)
end

local function _from_length_coded_bin(data, pos)
    local first = strbyte(data, pos)
    if not first then return nil, pos end
    if first <= 250 then return first, pos + 1 end
    if first == 251 then return nil, pos + 1 end
    if first == 252 then return _get_byte2(data, pos + 1) end
    if first == 253 then return _get_byte3(data, pos + 1) end
    if first == 254 then
        local v, p = strunpack("<I8", data, pos + 1)
        return v, p
    end
    return false, pos + 1
end

local function _set_length_coded_bin(n)
    if n < 251 then return strchar(n) end
    if n < (1 << 16) then return strpack("<BI2", 0xfc, n) end
    if n < (1 << 24) then return strpack("<BI3", 0xfd, n) end
    return strpack("<BI8", 0xfe, n)
end

local function _from_length_coded_str(data, pos)
    local len
    len, pos = _from_length_coded_bin(data, pos)
    if len == nil then return nil, pos end
    return sub(data, pos, pos + len - 1), pos + len
end

-- ============================================================================
-- Token computation (SHA1-based challenge-response)
-- ============================================================================

local function _compute_token(password, scramble)
    if password == "" then return "" end
    local stage1 = sha1(password)
    local stage2 = sha1(stage1)
    local stage3 = sha1(scramble .. stage2)
    local i = 0
    return strgsub(stage3, ".", function(x)
        i = i + 1
        return strchar(strbyte(x) ~ strbyte(stage1, i))
    end)
end

-- ============================================================================
-- Packet construction & reception
-- ============================================================================

local function _compose_packet(self, req)
    self.packet_no = self.packet_no + 1
    local size = #req
    return strpack("<I3Bc" .. size, size, self.packet_no, req)
end

local function _recv_packet(self, sock)
    local data = sock:read(4)
    if not data then return nil, nil, "failed to receive packet header" end

    local len, pos = _get_byte3(data, 1)
    if len == 0 then return nil, nil, "empty packet" end

    self.packet_no = strbyte(data, pos)
    data = sock:read(len)
    if not data then return nil, nil, "failed to read packet content" end

    local field_count = strbyte(data, 1)
    local typ
    if field_count == 0x00 then typ = "OK"
    elseif field_count == 0xff then typ = "ERR"
    elseif field_count == 0xfe then typ = "EOF"
    else typ = "DATA"
    end

    return data, typ
end

-- ============================================================================
-- Packet parsing
-- ============================================================================

local function _parse_ok_packet(packet)
    local res = {}
    local pos
    res.affected_rows, pos = _from_length_coded_bin(packet, 2)
    res.insert_id, pos = _from_length_coded_bin(packet, pos)
    res.server_status, pos = _get_byte2(packet, pos)
    res.warning_count, pos = _get_byte2(packet, pos)
    local message = sub(packet, pos)
    if message and message ~= "" then res.message = message end
    return res
end

local function _parse_eof_packet(packet)
    local warning_count, pos = _get_byte2(packet, 2)
    local status_flags = _get_byte2(packet, pos)
    return warning_count, status_flags
end

local function _parse_err_packet(packet)
    local errno, pos = _get_byte2(packet, 2)
    local marker = sub(packet, pos, pos)
    local sqlstate
    if marker == '#' then
        pos = pos + 1
        sqlstate = sub(packet, pos, pos + 5 - 1)
        pos = pos + 5
    end
    local message = sub(packet, pos)
    return errno, message, sqlstate
end

local function _parse_field_packet(data)
    local col = {}
    local pos
    local catalog
    catalog, pos = _from_length_coded_str(data, 1)
    local db
    db, pos = _from_length_coded_str(data, pos)
    local tbl
    tbl, pos = _from_length_coded_str(data, pos)
    local orig_table
    orig_table, pos = _from_length_coded_str(data, pos)
    col.name, pos = _from_length_coded_str(data, pos)
    local orig_name
    orig_name, pos = _from_length_coded_str(data, pos)
    pos = pos + 1  -- filler
    local charsetnr
    charsetnr, pos = _get_byte2(data, pos)
    local length
    length, pos = _get_byte4(data, pos)
    col.type = strbyte(data, pos)
    pos = pos + 1
    local flags
    flags, pos = _get_byte2(data, pos)
    if flags & 0x20 == 0 then
        col.is_signed = true
    end
    return col
end

local function _parse_row_data_packet(data, cols, compact)
    local pos = 1
    local ncols = #cols
    local row = {}
    for i = 1, ncols do
        local value
        value, pos = _from_length_coded_str(data, pos)
        local col = cols[i]
        if value ~= nil then
            local conv = converters[col.type]
            if conv then value = conv(value) end
        end
        if compact then row[i] = value
        else row[col.name] = value
        end
    end
    return row
end

local function _recv_field_packet(self, sock)
    local packet, typ, err = _recv_packet(self, sock)
    if not packet then return nil, err end
    if typ == "ERR" then
        local errno, msg, sqlstate = _parse_err_packet(packet)
        return nil, msg, errno, sqlstate
    end
    if typ ~= "DATA" then return nil, "bad field packet type: " .. typ end
    return _parse_field_packet(packet)
end

-- ============================================================================
-- Login / Auth
-- ============================================================================

local function _recv_decode_packet_resp(self)
    return function(sock)
        local packet, typ, err = _recv_packet(self, sock)
        if not packet then
            return false, "failed to receive the result packet: " .. (err or "")
        end
        if typ == "ERR" then
            local errno, msg, sqlstate = _parse_err_packet(packet)
            return false, strformat("errno:%d, msg:%s, sqlstate:%s", errno, msg, sqlstate or "")
        end
        if typ == "EOF" then
            return false, "old pre-4.1 authentication protocol not supported"
        end
        return true, packet
    end
end

local function _mysql_login(self, user, password, charset, database, on_connect)
    return function(sockchannel)
        local dispatch_resp = _recv_decode_packet_resp(self)
        local packet = sockchannel:response(dispatch_resp)

        self.protocol_ver = strbyte(packet)
        local server_ver, pos = _from_cstring(packet, 2)
        if not server_ver then error "bad handshake: bad server version" end
        self._server_ver = server_ver

        local thread_id
        thread_id, pos = _get_byte4(packet, pos)
        local scramble1 = sub(packet, pos, pos + 8 - 1)
        if not scramble1 then error "1st part of scramble not found" end
        pos = pos + 9  -- skip filler

        self._server_capabilities, pos = _get_byte2(packet, pos)
        self._server_lang = strbyte(packet, pos)
        pos = pos + 1
        self._server_status, pos = _get_byte2(packet, pos)

        local more_capabilities
        more_capabilities, pos = _get_byte2(packet, pos)
        self._server_capabilities = self._server_capabilities | (more_capabilities << 16)

        local len = 21 - 8 - 1
        pos = pos + 1 + 10

        local scramble_part2 = sub(packet, pos, pos + len - 1)
        if not scramble_part2 then error "2nd part of scramble not found" end

        local scramble = scramble1 .. scramble_part2
        local token = _compute_token(password, scramble)
        local client_flags = 260047
        local req = strpack("<I4I4c1c23zs1z",
            client_flags,
            self._max_packet_size,
            strchar(charset),
            strrep("\0", 23),
            user,
            token,
            database
        )
        local authpacket = _compose_packet(self, req)
        sockchannel:request(authpacket, dispatch_resp)
        if on_connect then on_connect(self) end
    end
end

-- ============================================================================
-- Query
-- ============================================================================

local function _compose_query(self, query)
    self.packet_no = -1
    return _compose_packet(self, COM_QUERY .. query)
end

local function read_result(self, sock)
    local packet, typ, err = _recv_packet(self, sock)
    if not packet then return nil, err end

    if typ == "ERR" then
        local errno, msg, sqlstate = _parse_err_packet(packet)
        return nil, msg, errno, sqlstate
    end

    if typ == "OK" then
        local res = _parse_ok_packet(packet)
        if res and res.server_status & SERVER_MORE_RESULTS_EXISTS ~= 0 then
            return res, "again"
        end
        return res
    end

    if typ ~= "DATA" then return nil, "packet type " .. typ .. " not supported" end

    local field_count = _from_length_coded_bin(packet, 1)
    local cols = {}
    for i = 1, field_count do
        local col, cerr = _recv_field_packet(self, sock)
        if not col then return nil, cerr end
        cols[i] = col
    end

    -- EOF after column definitions
    packet, typ, err = _recv_packet(self, sock)
    if not packet then return nil, err end
    if typ ~= "EOF" then return nil, "unexpected packet type " .. typ end

    local compact = self.compact
    local rows = {}
    local i = 0
    while true do
        packet, typ, err = _recv_packet(self, sock)
        if not packet then return nil, err end
        if typ == "EOF" then
            local _, status_flags = _parse_eof_packet(packet)
            if status_flags & SERVER_MORE_RESULTS_EXISTS ~= 0 then
                return rows, "again"
            end
            break
        end
        i = i + 1
        rows[i] = _parse_row_data_packet(packet, cols, compact)
    end
    return rows
end

local function _query_resp(self)
    return function(sock)
        local res, err, errno, sqlstate = read_result(self, sock)
        if not res then
            return true, { badresult = true, err = err, errno = errno, sqlstate = sqlstate }
        end
        if err ~= "again" then return true, res end
        local multiresultset = { res, multiresultset = true }
        local i = 2
        while err == "again" do
            res, err, errno, sqlstate = read_result(self, sock)
            if not res then
                multiresultset.badresult = true
                multiresultset.err = err
                multiresultset.errno = errno
                multiresultset.sqlstate = sqlstate
                return true, multiresultset
            end
            multiresultset[i] = res
            i = i + 1
        end
        return true, multiresultset
    end
end

-- ============================================================================
-- Prepared statements
-- ============================================================================

local function _compose_stmt_prepare(self, query)
    self.packet_no = -1
    return _compose_packet(self, COM_STMT_PREPARE .. query)
end

local store_types = {
    number = function(v)
        if not tointeger(v) then
            return _set_byte2(0x05), _set_double(v)
        else
            return _set_byte2(0x08), _set_int8(v)
        end
    end,
    string = function(v)
        return _set_byte2(0x0f), _set_length_coded_bin(#v) .. v
    end,
    boolean = function(v)
        if v then return _set_byte2(0x01), strchar(1)
        else return _set_byte2(0x01), strchar(0)
        end
    end,
}
store_types["nil"] = function()
    return _set_byte2(0x06), ""
end

local function _compose_stmt_execute(self, stmt, cursor_type, args)
    local arg_num = args.n
    if arg_num ~= stmt.param_count then
        error("require param_count " .. stmt.param_count .. " got " .. arg_num)
    end
    self.packet_no = -1
    local cmd_packet = strpack("<c1I4BI4", COM_STMT_EXECUTE, stmt.prepare_id, cursor_type, 0x01)

    if arg_num > 0 then
        local types_buf = ""
        local values_buf = ""
        local null_count = (arg_num + 7) // 8
        local null_map = ""
        local field_index = 1
        for i = 1, null_count do
            local byte = 0
            for j = 0, 7 do
                if field_index <= arg_num then
                    if args[field_index] == nil then
                        byte = byte | (1 << j)
                    end
                end
                field_index = field_index + 1
            end
            null_map = null_map .. strchar(byte)
        end
        for i = 1, arg_num do
            local v = args[i]
            local f = store_types[type(v)]
            if not f then error("invalid parameter type " .. type(v)) end
            local ts, vs = f(v)
            types_buf = types_buf .. ts
            values_buf = values_buf .. vs
        end
        cmd_packet = cmd_packet .. null_map .. strchar(0x01) .. types_buf .. values_buf
    end
    return _compose_packet(self, cmd_packet)
end

-- Binary row parsing helpers
local function _get_datetime(data, pos)
    local len
    len, pos = _from_length_coded_bin(data, pos)
    if len == 7 then
        local year, month, day, hour, minute, second
        year, month, day, hour, minute, second, pos = string.unpack("<I2BBBBB", data, pos)
        return strformat("%04d-%02d-%02d %02d:%02d:%02d", year, month, day, hour, minute, second), pos
    elseif len == 4 then
        local year, month, day
        year, month, day, pos = string.unpack("<I2BB", data, pos)
        return strformat("%04d-%02d-%02d 00:00:00", year, month, day), pos
    else
        return "0000-00-00 00:00:00", pos + len
    end
end

local function _get_date(data, pos)
    local len
    len, pos = _from_length_coded_bin(data, pos)
    if len == 4 then
        local year, month, day
        year, month, day, pos = string.unpack("<I2BB", data, pos)
        return strformat("%04d-%02d-%02d", year, month, day), pos
    else
        error("unsupported date format, len=" .. len)
    end
end

local _binary_parser = {
    [0x01] = _get_int1, [0x02] = _get_int2, [0x03] = _get_int4,
    [0x04] = _get_float, [0x05] = _get_double,
    [0x07] = _get_datetime, [0x08] = _get_int8, [0x09] = _get_int3,
    [0x0a] = _get_date, [0x0c] = _get_datetime,
    [0x0f] = _from_length_coded_str, [0x10] = _from_length_coded_str,
    [0xf5] = _from_length_coded_str, [0xf9] = _from_length_coded_str,
    [0xfa] = _from_length_coded_str, [0xfb] = _from_length_coded_str,
    [0xfc] = _from_length_coded_str, [0xfd] = _from_length_coded_str,
    [0xfe] = _from_length_coded_str,
}

local function _parse_row_data_binary(data, cols, compact)
    local ncols = #cols
    local null_count = (ncols + 9) // 8
    local pos = 2 + null_count
    local null_fields = {}
    local field_index = 1
    for i = 2, pos - 1 do
        local byte = strbyte(data, i)
        for j = 0, 7 do
            if field_index > 2 then
                null_fields[field_index - 2] = (byte & (1 << j)) ~= 0
            end
            field_index = field_index + 1
        end
    end

    local row = {}
    for i = 1, ncols do
        if not null_fields[i] then
            local col = cols[i]
            local parser = _binary_parser[col.type]
            if not parser then error("unsupported field type " .. col.type) end
            local value
            value, pos = parser(data, pos, col.is_signed)
            if compact then row[i] = value
            else row[col.name] = value
            end
        end
    end
    return row
end

local function read_execute_result(self, sock)
    local packet, typ, err = _recv_packet(self, sock)
    if not packet then return nil, err end
    if typ == "ERR" then
        local errno, msg, sqlstate = _parse_err_packet(packet)
        return nil, msg, errno, sqlstate
    end
    if typ == "OK" then
        local res = _parse_ok_packet(packet)
        if res and res.server_status & SERVER_MORE_RESULTS_EXISTS ~= 0 then
            return res, "again"
        end
        return res
    end
    if typ ~= "DATA" then return nil, "packet type " .. typ .. " not supported" end

    local cols = {}
    while true do
        packet, typ, err = _recv_packet(self, sock)
        if typ == "EOF" then break end
        local col = _parse_field_packet(packet)
        if not col then break end
        table.insert(cols, col)
    end
    if #cols < 1 then return {} end

    local compact = self.compact
    local rows = {}
    while true do
        packet, typ, err = _recv_packet(self, sock)
        if typ == "EOF" then
            local _, status_flags = _parse_eof_packet(packet)
            if status_flags & SERVER_MORE_RESULTS_EXISTS ~= 0 then
                return rows, "again"
            end
            break
        end
        table.insert(rows, _parse_row_data_binary(packet, cols, compact))
    end
    return rows
end

local function read_prepare_result(self, sock)
    local resp = {}
    local packet, typ, err = _recv_packet(self, sock)
    if not packet then
        return false, { badresult = true, errno = 300101, err = err }
    end
    if typ == "ERR" then
        local errno, msg, sqlstate = _parse_err_packet(packet)
        return true, { badresult = true, errno = errno, err = msg, sqlstate = sqlstate }
    end
    if typ ~= "OK" then
        return false, { badresult = true, errno = 300201, err = "first typ must be OK, got " .. typ }
    end

    resp.prepare_id, resp.field_count, resp.param_count, resp.warning_count =
        strunpack("<I4I2I2xI2", packet, 2)
    resp.params = {}
    resp.fields = {}

    if resp.param_count > 0 then
        local param = _recv_field_packet(self, sock)
        while param do
            table.insert(resp.params, param)
            param = _recv_field_packet(self, sock)
        end
    end
    if resp.field_count > 0 then
        local field = _recv_field_packet(self, sock)
        while field do
            table.insert(resp.fields, field)
            field = _recv_field_packet(self, sock)
        end
    end
    return true, resp
end

-- ============================================================================
-- Public API
-- ============================================================================

function _M.connect(opts)
    local self = setmetatable({}, mt)
    self._max_packet_size = opts.max_packet_size or 1024 * 1024
    self.compact = opts.compact_arrays

    local database = opts.database or ""
    local user = opts.user or ""
    local password = opts.password or ""
    local charset = CHARSET_MAP[opts.charset or "_default"]

    local channel = socketchannel.channel {
        host = opts.host,
        port = opts.port or 3306,
        auth = _mysql_login(self, user, password, charset, database, opts.on_connect),
    }
    self.sockchannel = channel
    channel:connect(true)
    return self
end

function _M.disconnect(self)
    self.sockchannel:close()
    setmetatable(self, nil)
end

function _M.query(self, query)
    local querypacket = _compose_query(self, query)
    if not self.query_resp then
        self.query_resp = _query_resp(self)
    end
    return self.sockchannel:request(querypacket, self.query_resp)
end

function _M.prepare(self, sql)
    local querypacket = _compose_stmt_prepare(self, sql)
    if not self.prepare_resp then
        self.prepare_resp = function(sock) return read_prepare_result(self, sock) end
    end
    return self.sockchannel:request(querypacket, self.prepare_resp)
end

function _M.execute(self, stmt, ...)
    local querypacket = _compose_stmt_execute(self, stmt, CURSOR_TYPE_NO_CURSOR, table.pack(...))
    if not self.execute_resp then
        self.execute_resp = function(sock)
            local res, err, errno, sqlstate = read_execute_result(self, sock)
            if not res then
                return true, { badresult = true, err = err, errno = errno, sqlstate = sqlstate }
            end
            if err ~= "again" then return true, res end
            local multi = { res, multiresultset = true }
            local i = 2
            while err == "again" do
                res, err, errno, sqlstate = read_execute_result(self, sock)
                if not res then
                    multi.badresult = true
                    multi.err = err
                    return true, multi
                end
                multi[i] = res
                i = i + 1
            end
            return true, multi
        end
    end
    return self.sockchannel:request(querypacket, self.execute_resp)
end

function _M.stmt_reset(self, stmt)
    self.packet_no = -1
    local cmd = strpack("c1<I4", COM_STMT_RESET, stmt.prepare_id)
    local querypacket = _compose_packet(self, cmd)
    if not self.query_resp then
        self.query_resp = _query_resp(self)
    end
    return self.sockchannel:request(querypacket, self.query_resp)
end

function _M.stmt_close(self, stmt)
    self.packet_no = -1
    local cmd = strpack("c1<I4", COM_STMT_CLOSE, stmt.prepare_id)
    local querypacket = _compose_packet(self, cmd)
    return self.sockchannel:request(querypacket)
end

function _M.ping(self)
    self.packet_no = -1
    local pingpacket = _compose_packet(self, COM_PING)
    if not self.query_resp then
        self.query_resp = _query_resp(self)
    end
    return self.sockchannel:request(pingpacket, self.query_resp)
end

function _M.server_ver(self)
    return self._server_ver
end

function _M._selftest()
    local function packet(seq, payload)
        return strpack("<I3B", #payload, seq or 0) .. payload
    end
    local function sock_from(data)
        return {
            data = data,
            pos = 1,
            read = function(self, n)
                if self.pos > #self.data then return nil end
                local out = sub(self.data, self.pos, self.pos + n - 1)
                self.pos = self.pos + #out
                if #out < n then return nil end
                return out
            end,
        }
    end

    assert(_get_int1("\255", 1, false) == 255)
    assert(_get_int1("\255", 1, true) == -1)
    assert(_get_int2("\255\255", 1, false) == 65535)
    assert(_get_int2("\255\255", 1, true) == -1)
    assert(_get_int3("\255\255\255", 1, false) == 16777215)
    assert(_get_int3("\255\255\255", 1, true) == -1)
    assert(_get_int4("\255\255\255\255", 1, false) == 4294967295)
    assert(_get_int4("\255\255\255\255", 1, true) == -1)
    assert(_get_float(string.pack("<f", 1.5), 1) > 1.4)
    assert(_get_double(string.pack("<d", 2.5), 1) > 2.4)

    assert(_from_length_coded_bin(string.char(250), 1) == 250)
    local v252 = _from_length_coded_bin(string.pack("<BI2", 252, 300), 1)
    local v253 = _from_length_coded_bin(string.pack("<BI3", 253, 70000), 1)
    local v254 = _from_length_coded_bin(string.pack("<BI8", 254, 123456789), 1)
    assert(v252 == 300 and v253 == 70000 and v254 == 123456789)
    local nullv = _from_length_coded_bin(string.char(251), 1)
    assert(nullv == nil)
    assert(_set_length_coded_bin(250) == string.char(250))
    assert(#_set_length_coded_bin(300) == 3)
    assert(#_set_length_coded_bin(70000) == 4)
    assert(#_set_length_coded_bin(123456789) == 9)

    local errno, msg, sqlstate = _parse_err_packet("\xff" .. string.pack("<I2", 1064) .. "#HY000bad sql")
    assert(errno == 1064 and msg == "bad sql" and sqlstate == "HY000")
    local ok_packet = "\0\1\2" .. string.pack("<I2I2", 8, 0) .. "changed"
    local ok = _parse_ok_packet(ok_packet)
    assert(ok.affected_rows == 1 and ok.insert_id == 2 and ok.server_status == 8 and ok.message == "changed")
    local warnings, status = _parse_eof_packet("\xfe" .. string.pack("<I2I2", 3, 8))
    assert(warnings == 3 and status == 8)

    local text_row = _parse_row_data_packet("\2" .. "42", { { name = "n", type = 0x03 } })
    assert(text_row.n == 42)
    local compact_row = _parse_row_data_packet("\2" .. "42", { { name = "n", type = 0x03 } }, true)
    assert(compact_row[1] == 42)
    local bin_row = _parse_row_data_binary("\0\0" .. string.pack("<i4", 7), { { name = "n", type = 0x03, is_signed = true } })
    assert(bin_row.n == 7)
    local dt = _get_datetime(string.char(7) .. string.pack("<I2BBBBB", 2026, 5, 1, 2, 3, 4), 1)
    assert(dt == "2026-05-01 02:03:04")
    local dt4 = _get_datetime(string.char(4) .. string.pack("<I2BB", 2026, 5, 1), 1)
    assert(dt4 == "2026-05-01 00:00:00")
    local dt0 = _get_datetime(string.char(0), 1)
    assert(dt0 == "0000-00-00 00:00:00")
    local d = _get_date(string.char(4) .. string.pack("<I2BB", 2026, 5, 1), 1)
    assert(d == "2026-05-01")
    assert(not pcall(_get_date, string.char(0), 1))
    assert(_compute_token("", "scramble") == "")
    assert(not pcall(_compose_stmt_execute, { packet_no = 0 }, { prepare_id = 1, param_count = 2 }, 0, table.pack(1)))

    local self = { packet_no = 0 }
    local okp, prep = read_prepare_result(self, sock_from(packet(1,
        "\xff" .. strpack("<I2", 1064) .. "#HY000bad prepare")))
    assert(okp == true and prep.badresult == true and prep.errno == 1064)
    okp, prep = read_prepare_result(self, sock_from(""))
    assert(okp == false and prep.errno == 300101)
    okp, prep = read_prepare_result(self, sock_from(packet(1, "\1")))
    assert(okp == false and prep.errno == 300201)

    local err_res, err_msg, err_no = read_result(self, sock_from(packet(1,
        "\xff" .. strpack("<I2", 1146) .. "#HY000missing table")))
    assert(err_res == nil and err_no == 1146 and err_msg == "missing table")
    local again = read_result(self, sock_from(packet(1, "\0\0\0" .. strpack("<I2I2", SERVER_MORE_RESULTS_EXISTS, 0))))
    assert(again and again.server_status == SERVER_MORE_RESULTS_EXISTS)
    local exec_again = read_execute_result(self, sock_from(packet(1, "\0\0\0" .. strpack("<I2I2", SERVER_MORE_RESULTS_EXISTS, 0))))
    assert(exec_again and exec_again.server_status == SERVER_MORE_RESULTS_EXISTS)
    return true
end

return _M
