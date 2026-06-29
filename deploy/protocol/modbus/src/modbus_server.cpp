// =============================================================================
// ModbusServer 实现 — 基于 libmodbus 的 TCP Server
// 使用原生 socket + libmodbus 实现多客户端并发连接
// =============================================================================

#include "modbus_server.h"

#include <algorithm>
#include <arpa/inet.h>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <iostream>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>



namespace rk3588 {
namespace protocol {
namespace modbus {

// =============================================================================
// ModbusServer 构造 / 析构
// =============================================================================

ModbusServer::ModbusServer(int port)
    : port_(port),
      listen_socket_(-1),
      running_(false) {}

ModbusServer::~ModbusServer() {
  Stop();
}

// =============================================================================
// Start / Stop
// =============================================================================

bool ModbusServer::Start() {
  if (running_.load()) {
    std::cerr << "[ModbusServer] 已在运行中" << std::endl;
    return false;
  }

  // ── 创建原生 TCP 监听 socket ──────────────────────────
  listen_socket_ = ::socket(AF_INET, SOCK_STREAM, 0);
  if (listen_socket_ < 0) {
    std::cerr << "[ModbusServer] socket() 失败: " << strerror(errno) << std::endl;
    return false;
  }

  // 设置 SO_REUSEADDR 允许快速重启
  int optval = 1;
  ::setsockopt(listen_socket_, SOL_SOCKET, SO_REUSEADDR, &optval, sizeof(optval));

  struct sockaddr_in addr {};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = INADDR_ANY;
  addr.sin_port = htons(static_cast<uint16_t>(port_));

  if (::bind(listen_socket_, reinterpret_cast<struct sockaddr*>(&addr),
             sizeof(addr)) < 0) {
    std::cerr << "[ModbusServer] bind() 失败: " << strerror(errno) << std::endl;
    ::close(listen_socket_);
    listen_socket_ = -1;
    return false;
  }

  if (::listen(listen_socket_, 5) < 0) {
    std::cerr << "[ModbusServer] listen() 失败: " << strerror(errno) << std::endl;
    ::close(listen_socket_);
    listen_socket_ = -1;
    return false;
  }

  running_.store(true);
  accept_thread_ = std::thread(&ModbusServer::AcceptLoop, this);

  std::cout << "[ModbusServer] 启动成功，监听 0.0.0.0:" << port_ << std::endl;
  return true;
}

void ModbusServer::Stop() {
  if (!running_.load()) return;
  running_.store(false);

  // 关闭监听 socket 以唤醒阻塞的 accept()
  if (listen_socket_ >= 0) {
    ::shutdown(listen_socket_, SHUT_RDWR);
    ::close(listen_socket_);
    listen_socket_ = -1;
  }

  if (accept_thread_.joinable()) {
    accept_thread_.join();
  }

  // 等待所有客户端线程退出
  // 由于 AcceptLoop 可能正在操作 vector，此处简单遍历 join
  for (auto& t : client_threads_) {
    if (t.joinable()) t.join();
  }

  std::cout << "[ModbusServer] 已停止" << std::endl;
}

// =============================================================================
// Accept 循环 — 原生 BSD socket accept
// =============================================================================

void ModbusServer::AcceptLoop() {
  while (running_.load()) {
    struct sockaddr_in client_addr {};
    socklen_t client_len = sizeof(client_addr);

    int client_fd = ::accept(listen_socket_,
                             reinterpret_cast<struct sockaddr*>(&client_addr),
                             &client_len);
    if (client_fd < 0) {
      if (errno == EINTR || errno == EBADF) break;  // 停止信号
      if (running_.load()) {
        std::cerr << "[ModbusServer] accept() 失败: "
                  << strerror(errno) << std::endl;
      }
      continue;
    }

    // 设置客户端 socket 超时 (500ms)
    struct timeval tv {};
    tv.tv_sec = 0;
    tv.tv_usec = 500000;
    ::setsockopt(client_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    ::setsockopt(client_fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    char ip_str[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &client_addr.sin_addr, ip_str, sizeof(ip_str));
    std::cout << "[ModbusServer] 新客户端连接 "
              << ip_str << ":" << ntohs(client_addr.sin_port)
              << "  fd=" << client_fd << std::endl;

    // 启动客户端处理线程
    client_threads_.emplace_back(&ModbusServer::ClientHandler, this, client_fd);

    // 清理已结束的线程
    client_threads_.erase(
        std::remove_if(client_threads_.begin(), client_threads_.end(),
                       [](std::thread& t) {
                         if (!t.joinable()) return true;
                         return false;
                       }),
        client_threads_.end());
  }
}

// =============================================================================
// 客户端处理线程
// =============================================================================

void ModbusServer::ClientHandler(int client_fd) {
  // 为每个客户端创建独立的 modbus 上下文
  modbus_t* ctx = modbus_new_tcp("0.0.0.0", port_);
  if (ctx == nullptr) {
    ::close(client_fd);
    return;
  }

  modbus_set_slave(ctx, 1);

  // 注入已 accept 的 socket
  if (modbus_set_socket(ctx, client_fd) < 0) {
    // modbus_set_socket 可能不存在于旧版本，回退到直接赋值
    // ctx->s = client_fd; // modbus_t is opaque in libmodbus v3.1
  }

  // 设置超时
  modbus_set_response_timeout(ctx, 0, 500000);  // 500ms

  // 分配寄存器映射 (只使用保持寄存器)
  const int kMaxRegisters = 65536;
  modbus_mapping_t* mapping = modbus_mapping_new(
      0,           // nb_bits (coils) — 不使用
      0,           // nb_input_bits — 不使用
      kMaxRegisters,  // nb_registers (holding)
      0);          // nb_input_registers — 不使用

  if (mapping == nullptr) {
    std::cerr << "[ModbusServer] modbus_mapping_new 失败" << std::endl;
    modbus_free(ctx);
    ::close(client_fd);
    return;
  }

  uint8_t query[MODBUS_TCP_MAX_ADU_LENGTH];

  while (running_.load()) {
    // 将最新寄存器值同步到本地 mapping
    register_map_.SyncToMapping(mapping);

    int rc = modbus_receive(ctx, query);
    if (rc < 0) {
      if (errno == ECONNRESET || errno == ECONNABORTED || errno == EPIPE ||
          errno == ETIMEDOUT) {
        break;
      }
      // 其他错误也断开
      break;
    }

    if (rc > 0) {
      // 处理 Modbus 请求
      modbus_reply(ctx, query, rc, mapping);

      // 回写客户端可能写入的寄存器
      register_map_.SyncFromMapping(mapping);
    }
  }

  modbus_mapping_free(mapping);
  modbus_free(ctx);
  ::close(client_fd);

  std::cout << "[ModbusServer] 客户端断开 fd=" << client_fd << std::endl;
}

// =============================================================================
// 寄存器读写 API
// =============================================================================

void ModbusServer::SetHoldingRegister(uint16_t addr, uint16_t value) {
  register_map_.WriteRegister(addr, value);
}

uint16_t ModbusServer::GetHoldingRegister(uint16_t addr) const {
  return register_map_.ReadRegister(addr);
}

void ModbusServer::SetCoil(uint16_t addr, bool value) {
  std::lock_guard<std::mutex> lock(coil_mutex_);
  coils_[addr] = value;
}

bool ModbusServer::GetCoil(uint16_t addr) const {
  std::lock_guard<std::mutex> lock(coil_mutex_);
  auto it = coils_.find(addr);
  return (it != coils_.end()) ? it->second : false;
}

// =============================================================================
// 高阶操作
// =============================================================================

void ModbusServer::UpdateDetections(const std::vector<Detection>& detections) {
  register_map_.UpdateDetections(detections);
}

void ModbusServer::UpdateHeartbeat() {
  ++heartbeat_;
  ++frame_counter_;
  register_map_.UpdateSystemStatus(
      heartbeat_.load(), status_.load(),
      frame_counter_.load(), fps_.load(), temperature_.load());
}

void ModbusServer::SetFps(float fps) {
  fps_.store(fps);
  register_map_.UpdateSystemStatus(
      heartbeat_.load(), status_.load(),
      frame_counter_.load(), fps, temperature_.load());
}

void ModbusServer::SetTemperature(float temp_c) {
  temperature_.store(temp_c);
  register_map_.UpdateSystemStatus(
      heartbeat_.load(), status_.load(),
      frame_counter_.load(), fps_.load(), temp_c);
}

void ModbusServer::SetStatus(uint16_t status) {
  status_.store(status);
  register_map_.UpdateSystemStatus(
      heartbeat_.load(), status,
      frame_counter_.load(), fps_.load(), temperature_.load());
}

bool ModbusServer::LoadRegisterMap(const std::string& yaml_path) {
  return register_map_.LoadFromYaml(yaml_path);
}

}  // namespace modbus
}  // namespace protocol
}  // namespace rk3588

