#pragma once

#include "network.h"
#include "skynet.h"

#include <functional>
#include <string>

namespace skynet {

// ============================================================================
// ServiceGate -- TCP gateway actor
//
// Listens on a TCP port, accepts connections, and dispatches socket events.
// Supports assigning an "agent" actor per connection: when set, socket data
// messages are forwarded to the agent instead of the gate's owner.
//
// Usage:
//   auto gate = sys.spawn<ServiceGate>("8888");
//   // gate will send SocketAccept / SocketData / SocketClose to itself
//   // override on_message or set an agent_factory to handle connections
// ============================================================================

class ServiceGate : public Actor {
public:
    // Callback: given connection_id, returns the agent actor handle.
    // If not set, all socket data stays with the gate actor.
    using AgentFactory = std::function<uint32_t(ServiceGate&, int conn_id,
                                                const std::string& addr,
                                                uint16_t port)>;

    void set_agent_factory(AgentFactory factory) {
        agent_factory_ = std::move(factory);
    }

    // Send data to a specific connection
    void send_to_client(int connection_id, std::string data) {
        if (listener_) listener_->send(connection_id, std::move(data));
    }

    // Close a specific connection
    void close_client(int connection_id) {
        if (listener_) listener_->close_connection(connection_id);
        agents_.erase(connection_id);
    }

    // Pause/resume reading on a connection (flow control)
    void pause_client(int connection_id) {
        auto conn = listener_ ? listener_->get_connection(connection_id)
                               : nullptr;
        if (conn) conn->pause();
    }

    void resume_client(int connection_id) {
        auto conn = listener_ ? listener_->get_connection(connection_id)
                               : nullptr;
        if (conn) conn->resume();
    }

protected:
    void on_init(std::string_view param) override {
        uint16_t port = 8888;
        if (!param.empty())
            port = static_cast<uint16_t>(std::stoi(std::string(param)));

        listener_ = std::make_shared<TcpListener>(
            system(), handle(), port, 0, "0.0.0.0", true /* nodelay */);
        listener_->start();

        system().error(handle(), "Gate listening on port %u", port);
    }

    void on_message(const Message& msg) override {
        if (msg.type != PTYPE_SOCKET) return;

        if (auto* ev = msg.get_if<SocketAccept>()) {
            on_accept(*ev);
        } else if (auto* ev = msg.get_if<SocketData>()) {
            on_data(*ev);
        } else if (auto* ev = msg.get_if<SocketClose>()) {
            on_close(*ev);
        } else if (auto* ev = msg.get_if<SocketWarning>()) {
            system().error(handle(),
                           "conn #%d send buffer warning: %zu bytes",
                           ev->connection_id, ev->pending_bytes);
        }
    }

    void on_destroy() override {
        if (listener_) listener_->stop();
    }

    // Override these in subclass for custom behavior
    virtual void on_accept(const SocketAccept& ev) {
        system().error(handle(), "+ conn #%d from %s:%u",
                       ev.connection_id,
                       ev.remote_address.c_str(),
                       ev.remote_port);

        if (agent_factory_) {
            uint32_t agent = agent_factory_(
                *this, ev.connection_id,
                ev.remote_address, ev.remote_port);
            if (agent != 0) {
                agents_[ev.connection_id] = agent;
            }
        }
    }

    virtual void on_data(const SocketData& ev) {
        auto it = agents_.find(ev.connection_id);
        if (it != agents_.end()) {
            // Forward to agent
            send(it->second, PTYPE_SOCKET,
                 SocketData{ev.listener_id, ev.connection_id, ev.data});
        }
        // If no agent, subclass should override on_data
    }

    virtual void on_close(const SocketClose& ev) {
        system().error(handle(), "- conn #%d closed", ev.connection_id);
        listener_->close_connection(ev.connection_id);
        agents_.erase(ev.connection_id);
    }

private:
    std::shared_ptr<TcpListener> listener_;
    AgentFactory agent_factory_;
    std::unordered_map<int, uint32_t> agents_;  // conn_id -> agent handle
};

} // namespace skynet
