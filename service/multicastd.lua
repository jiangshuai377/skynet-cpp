-- multicastd.lua — Multicast channel management service
--
-- Manages pub/sub channels. Subscribers receive messages published to a channel.
-- Single-node implementation (no harbor/cross-node support).

local skynet = require "skynet"

local channel_id = 0
local channels = {}       -- id -> { subscribers = { [addr] = true } }

local CMD = {}

function CMD.NEW(source)
    channel_id = channel_id + 1
    channels[channel_id] = { subscribers = {} }
    skynet.ret(skynet.pack(channel_id))
end

function CMD.DEL(source, id)
    channels[id] = nil
    skynet.ret(skynet.pack(nil))
end

function CMD.SUB(source, id, addr)
    addr = addr or source
    local ch = channels[id]
    if ch then
        ch.subscribers[addr] = true
    end
    skynet.ret(skynet.pack(nil))
end

function CMD.USUB(source, id, addr)
    addr = addr or source
    local ch = channels[id]
    if ch then
        ch.subscribers[addr] = nil
    end
    skynet.ret(skynet.pack(nil))
end

function CMD.PUB(source, id, ...)
    local ch = channels[id]
    if not ch then return end
    for addr in pairs(ch.subscribers) do
        -- Send as PTYPE_MULTICAST (type 2)
        local msg, sz = skynet.pack(id, ...)
        skynet.rawsend(addr, 2, 0, msg, sz)
    end
end

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local f = assert(CMD[cmd], "Unknown multicast command: " .. tostring(cmd))
        f(source, ...)
    end)
end)
