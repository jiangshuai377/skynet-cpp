#pragma once

#include "skynet.h"

#include <deque>
#include <functional>
#include <mutex>

namespace skynet {

// ============================================================================
// TcpConnection
// ============================================================================

class TcpConnection : public std::enable_shared_from_this<TcpConnection> {
public:
    TcpConnection(ActorSystem& sys, asio::ip::tcp::socket socket,
                  uint32_t owner, int listener_id, int id,
                  bool nodelay = false);

    int  id() const { return id_; }
    void start();
    void send(std::string data);
    void close();

    // Phase 2: flow control
    void pause();
    void resume();

    // Phase 2: half-close (send FIN, keep reading)
    void shutdown_write();

private:
    void do_read();
    void do_write();
    void check_send_warning();

    ActorSystem&            system_;
    uint32_t                owner_;
    int                     listener_id_;
    int                     id_;
    asio::ip::tcp::socket   socket_;
    std::array<char, 8192>  read_buf_;
    std::deque<std::string> write_queue_;
    bool                    is_writing_ = false;
    bool                    is_paused_  = false;
    size_t                  pending_bytes_ = 0;
    bool                    warned_ = false;
};

// ============================================================================
// TcpListener
// ============================================================================

class TcpListener : public std::enable_shared_from_this<TcpListener> {
public:
    TcpListener(ActorSystem& sys, uint32_t owner, uint16_t port,
                int listener_id, const std::string& host = "0.0.0.0",
                bool nodelay = false);

    void start();
    void stop();
    void send(int connection_id, std::string data);
    void close_connection(int connection_id);

    std::shared_ptr<TcpConnection> get_connection(int connection_id);

private:
    void do_accept();

    ActorSystem&     system_;
    uint32_t         owner_;
    bool             nodelay_;
    int              listener_id_;
    asio::ip::tcp::acceptor acceptor_;
    std::mutex conn_mutex_;
    std::unordered_map<int, std::shared_ptr<TcpConnection>> connections_;
};

// ============================================================================
// TcpConnector -- outbound async TCP connection
// ============================================================================

class TcpConnector : public std::enable_shared_from_this<TcpConnector> {
public:
    TcpConnector(ActorSystem& sys, uint32_t owner,
                 const std::string& host, uint16_t port,
                 bool nodelay = false);

    int  id() const { return id_; }
    void start();
    void send(std::string data);
    void close();

private:
    ActorSystem&  system_;
    uint32_t      owner_;
    int           id_;
    bool          nodelay_;
    std::string   host_;
    uint16_t      port_;

    asio::ip::tcp::resolver resolver_;
    asio::ip::tcp::socket   socket_;

    std::shared_ptr<TcpConnection> conn_;
};

// ============================================================================
// UdpSocket -- async UDP send/receive
// ============================================================================

class UdpSocket : public std::enable_shared_from_this<UdpSocket> {
public:
    UdpSocket(ActorSystem& sys, uint32_t owner, uint16_t port);
    UdpSocket(ActorSystem& sys, uint32_t owner, int id,
              const std::string& host, uint16_t port);

    void start();
    void stop();
    void send_to(std::string data, const std::string& host, uint16_t port);

private:
    void do_receive();

    ActorSystem&          system_;
    uint32_t              owner_;
    int                   id_;
    asio::ip::udp::socket socket_;
    asio::ip::udp::endpoint remote_ep_;
    std::array<char, 65536> recv_buf_;
};

} // namespace skynet
