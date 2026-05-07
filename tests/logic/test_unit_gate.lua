local skynet = require "skynet"
local gateserver = require "gateserver"

local listener

local handler = {}

function handler.open(_, conf)
    listener = conf.port
end

function handler.connect(conn_id)
    skynet.name(".unit_gate_conn", conn_id)
end

function handler.disconnect(conn_id)
    skynet.name(".unit_gate_disconnected", conn_id)
end

function handler.message(conn_id, data)
    skynet.name(".unit_gate_msg", conn_id)
    skynet.name(".unit_gate_msg_len", #data)
end

function handler.warning(conn_id, bytes)
    skynet.name(".unit_gate_warning_conn", conn_id)
    skynet.name(".unit_gate_warning_bytes", bytes)
end

skynet.start(function()
    gateserver.start(handler)
end)
