-- multicast.lua — Multicast pub/sub client library
--
-- Create channels, publish messages, and subscribe to receive them.
-- Usage:
--   local multicast = require "skynet.multicast"
--   local mc = multicast.new()  -- create a new channel
--   mc:subscribe()
--   mc.dispatch = function(channel, source, ...) end
--   -- From another service:
--   mc:publish(...)

local skynet = require "skynet"

local multicast = {}
local multicast_mt = {}
multicast_mt.__index = multicast_mt

local service

local function init_service()
    if not service then
        service = skynet.uniqueservice("multicastd")
        skynet.sleep(5)
    end
end

-- Register PTYPE_MULTICAST protocol
local PTYPE_MULTICAST = 2
local multicast_dispatchers = {}  -- channel_id -> dispatch function

skynet.register_protocol {
    name = "multicast",
    id = PTYPE_MULTICAST,
    unpack = skynet.unpack,
    dispatch = function(session, source, channel_id, ...)
        local d = multicast_dispatchers[channel_id]
        if d then
            d(channel_id, source, ...)
        end
    end,
}

--- Create a new multicast channel.
-- opts = { channel = existing_id } or nil for new channel
function multicast.new(opts)
    init_service()
    local self = setmetatable({}, multicast_mt)
    if opts and opts.channel then
        self.channel = opts.channel
    else
        self.channel = skynet.call(service, "lua", "NEW")
    end
    return self
end

--- Delete this channel.
function multicast_mt:delete()
    skynet.call(service, "lua", "DEL", self.channel)
    multicast_dispatchers[self.channel] = nil
end

--- Subscribe current service to this channel.
function multicast_mt:subscribe()
    skynet.call(service, "lua", "SUB", self.channel)
    multicast_dispatchers[self.channel] = function(channel, source, ...)
        if self.dispatch then
            self.dispatch(channel, source, ...)
        end
    end
end

--- Unsubscribe current service from this channel.
function multicast_mt:unsubscribe()
    skynet.call(service, "lua", "USUB", self.channel)
    multicast_dispatchers[self.channel] = nil
end

--- Publish a message to the channel.
function multicast_mt:publish(...)
    skynet.send(service, "lua", "PUB", self.channel, ...)
end

return multicast
