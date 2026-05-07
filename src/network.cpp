#include "network.h"

namespace skynet {

static asio::ip::address make_bind_address(const std::string& host) {
    if (host.empty() || host == "*" || host == "0.0.0.0") {
        return asio::ip::address_v4::any();
    }
    return asio::ip::make_address(host);
}

static std::atomic<int> s_next_accepted_connection_id{1};

// ============================================================================
// TcpConnection
// ============================================================================

TcpConnection::TcpConnection(ActorSystem& sys, asio::ip::tcp::socket socket,
                             uint32_t owner, int listener_id, int id,
                             bool nodelay)
    : system_(sys)
    , owner_(owner)
    , listener_id_(listener_id)
    , id_(id)
    , socket_(std::move(socket)) {
    if (nodelay) {
        asio::error_code ec;
        socket_.set_option(asio::ip::tcp::no_delay(true), ec);
    }
}

void TcpConnection::start() { do_read(); }

void TcpConnection::send(std::string data) {
    auto self = shared_from_this();
    asio::post(socket_.get_executor(),
               [this, self, d = std::move(data)]() mutable {
                   pending_bytes_ += d.size();
                   write_queue_.push_back(std::move(d));
                   check_send_warning();
                   if (!is_writing_) do_write();
               });
}

void TcpConnection::close() {
    auto self = shared_from_this();
    asio::post(socket_.get_executor(), [this, self]() {
        asio::error_code ec;
        socket_.shutdown(asio::ip::tcp::socket::shutdown_both, ec);
        socket_.close(ec);
    });
}

void TcpConnection::pause() {
    auto self = shared_from_this();
    asio::post(socket_.get_executor(), [this, self]() {
        is_paused_ = true;
    });
}

void TcpConnection::resume() {
    auto self = shared_from_this();
    asio::post(socket_.get_executor(), [this, self]() {
        if (is_paused_) {
            is_paused_ = false;
            do_read();
        }
    });
}

void TcpConnection::shutdown_write() {
    auto self = shared_from_this();
    asio::post(socket_.get_executor(), [this, self]() {
        asio::error_code ec;
        socket_.shutdown(asio::ip::tcp::socket::shutdown_send, ec);
    });
}

void TcpConnection::do_read() {
    if (is_paused_) return;
    auto self = shared_from_this();
    socket_.async_read_some(
        asio::buffer(read_buf_),
        [this, self](const asio::error_code& ec, std::size_t bytes) {
            if (ec) {
                system_.send(0, owner_, PTYPE_SOCKET, 0,
                             SocketClose{listener_id_, id_});
                return;
            }
            system_.send(0, owner_, PTYPE_SOCKET, 0,
                         SocketData{listener_id_, id_,
                                    std::string(read_buf_.data(), bytes)});
            do_read();
        });
}

void TcpConnection::do_write() {
    if (write_queue_.empty()) {
        is_writing_ = false;
        return;
    }
    is_writing_ = true;
    auto self   = shared_from_this();
    asio::async_write(
        socket_, asio::buffer(write_queue_.front()),
        [this, self](const asio::error_code& ec, std::size_t n) {
            if (ec) {
                system_.send(0, owner_, PTYPE_SOCKET, 0,
                             SocketClose{listener_id_, id_});
                return;
            }
            pending_bytes_ -= write_queue_.front().size();
            warned_ = false;  // reset warning once some data is sent
            write_queue_.pop_front();
            do_write();
        });
}

void TcpConnection::check_send_warning() {
    if (!warned_ && pending_bytes_ >= ActorSystem::SEND_BUFFER_WARNING) {
        warned_ = true;
        system_.send(0, owner_, PTYPE_SOCKET, 0,
                     SocketWarning{listener_id_, id_, pending_bytes_});
    }
}

// ============================================================================
// TcpListener
// ============================================================================

TcpListener::TcpListener(ActorSystem& sys, uint32_t owner, uint16_t port,
                         int listener_id, const std::string& host,
                         bool nodelay)
    : system_(sys)
    , owner_(owner)
    , nodelay_(nodelay)
    , listener_id_(listener_id)
    , acceptor_(sys.io_context()) {
    auto endpoint = asio::ip::tcp::endpoint(make_bind_address(host), port);
    acceptor_.open(endpoint.protocol());
    acceptor_.set_option(asio::ip::tcp::acceptor::reuse_address(true));
    acceptor_.bind(endpoint);
    acceptor_.listen();
}

void TcpListener::start() { do_accept(); }

void TcpListener::stop() {
    auto self = shared_from_this();
    asio::post(acceptor_.get_executor(), [this, self]() {
        asio::error_code ec;
        acceptor_.close(ec);
    });
}

void TcpListener::send(int connection_id, std::string data) {
    auto conn = get_connection(connection_id);
    if (conn) conn->send(std::move(data));
}

void TcpListener::close_connection(int connection_id) {
    std::shared_ptr<TcpConnection> conn;
    {
        std::lock_guard lock(conn_mutex_);
        auto it = connections_.find(connection_id);
        if (it == connections_.end()) return;
        conn = it->second;
        connections_.erase(it);
    }
    conn->close();
}

std::shared_ptr<TcpConnection> TcpListener::get_connection(int connection_id) {
    std::lock_guard lock(conn_mutex_);
    auto it = connections_.find(connection_id);
    return it != connections_.end() ? it->second : nullptr;
}

void TcpListener::do_accept() {
    auto self = shared_from_this();
    acceptor_.async_accept(
        [this, self](const asio::error_code& ec, asio::ip::tcp::socket socket) {
            if (ec) return;

            int  conn_id = s_next_accepted_connection_id.fetch_add(
                1, std::memory_order_relaxed);
            auto remote  = socket.remote_endpoint();
            auto conn    = std::make_shared<TcpConnection>(
                system_, std::move(socket), owner_, listener_id_, conn_id,
                nodelay_);

            {
                std::lock_guard lock(conn_mutex_);
                connections_[conn_id] = conn;
            }

            conn->start();

            system_.send(0, owner_, PTYPE_SOCKET, 0,
                         SocketAccept{listener_id_, conn_id,
                                      remote.address().to_string(),
                                      remote.port()});

            do_accept();
        });
}

// ============================================================================
// TcpConnector
// ============================================================================

static std::atomic<int> s_next_connector_id{1000000};

TcpConnector::TcpConnector(ActorSystem& sys, uint32_t owner,
                           const std::string& host, uint16_t port,
                           bool nodelay)
    : system_(sys)
    , owner_(owner)
    , id_(s_next_connector_id.fetch_add(1, std::memory_order_relaxed))
    , nodelay_(nodelay)
    , host_(host)
    , port_(port)
    , resolver_(sys.io_context())
    , socket_(sys.io_context()) {}

void TcpConnector::start() {
    auto self = shared_from_this();
    resolver_.async_resolve(
        host_, std::to_string(port_),
        [this, self](const asio::error_code& ec,
                     asio::ip::tcp::resolver::results_type results) {
            if (ec) {
                system_.send(0, owner_, PTYPE_SOCKET, 0,
                             SocketClose{0, id_});
                return;
            }
            asio::async_connect(
                socket_, results,
                [this, self](const asio::error_code& ec,
                             const asio::ip::tcp::endpoint& ep) {
                    if (ec) {
                        system_.send(0, owner_, PTYPE_SOCKET, 0,
                                     SocketClose{0, id_});
                        return;
                    }
                    conn_ = std::make_shared<TcpConnection>(
                        system_, std::move(socket_), owner_, 0, id_, nodelay_);
                    conn_->start();

                    system_.send(0, owner_, PTYPE_SOCKET, 0,
                                 SocketOpen{id_, ep.address().to_string(),
                                            ep.port()});
                });
        });
}

void TcpConnector::send(std::string data) {
    if (conn_) conn_->send(std::move(data));
}

void TcpConnector::close() {
    if (conn_) conn_->close();
}

// ============================================================================
// UdpSocket
// ============================================================================

UdpSocket::UdpSocket(ActorSystem& sys, uint32_t owner, uint16_t port)
    : UdpSocket(sys, owner, 0, "0.0.0.0", port) {}

UdpSocket::UdpSocket(ActorSystem& sys, uint32_t owner, int id,
                     const std::string& host, uint16_t port)
    : system_(sys)
    , owner_(owner)
    , id_(id)
    , socket_(sys.io_context(),
              asio::ip::udp::endpoint(make_bind_address(host), port)) {}

void UdpSocket::start() { do_receive(); }

void UdpSocket::stop() {
    auto self = shared_from_this();
    asio::post(socket_.get_executor(), [this, self]() {
        asio::error_code ec;
        socket_.close(ec);
    });
}

void UdpSocket::send_to(std::string data, const std::string& host,
                        uint16_t port) {
    auto self = shared_from_this();
    auto ep = asio::ip::udp::endpoint(
        asio::ip::make_address(host), port);
    auto payload = std::make_shared<std::string>(std::move(data));
    socket_.async_send_to(
        asio::buffer(*payload), ep,
        [self, payload](const asio::error_code&, std::size_t) {});
}

void UdpSocket::do_receive() {
    auto self = shared_from_this();
    socket_.async_receive_from(
        asio::buffer(recv_buf_), remote_ep_,
        [this, self](const asio::error_code& ec, std::size_t bytes) {
            if (ec) return;

            system_.send(0, owner_, PTYPE_SOCKET, 0,
                         SocketUDP{id_, std::string(recv_buf_.data(), bytes),
                                   remote_ep_.address().to_string(),
                                   remote_ep_.port()});
            do_receive();
        });
}

} // namespace skynet
