// =============================================================================
// ModbusServer 实现 — 基于 libmodbus 的 TCP Server
// =============================================================================

#include "modbus_server.h"

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <iostream>
#include <sstream>
#include <system_error>

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

  modbus_t* ctx = modbus_new_tcp("0.0.0.0", std::to_string(port_).c_str());
  if (ctx == nullptr) {
    std::cerr << "[ModbusServer] modbus_new_tcp 失败: " << modbus_strerror(errno)
              << std::endl;
    return false;
  }

  // 设置从机 ID = 1
  modbus_set_slave(ctx, 1);

  listen_socket_ = modbus_tcp_listen(ctx, 5);
  if (listen_socket_ < 0) {
    std::cerr << "[ModbusServer] modbus_tcp_listen 失败: "
              << modbus_strerror(errno) << std::endl;
    modbus_free(ctx);
    return false;
  }

  modbus_free(ctx);  // listen ctx 不再需要，accept 时重建

  running_.store(true);
  accept_thread_ = std::thread(&ModbusServer::AcceptLoop, this);

  std::cout << "[ModbusServer] 启动成功，监听端口 " << port_ << std::endl;
  return true;
}

void ModbusServer::Stop() {
  if (!running_.load()) return;
  running_.store(false);

  // 关闭监听 socket 以唤醒 accept
  if (listen_socket_ >= 0) {
    ::shutdown(listen_socket_, SHUT_RDWR);
    ::close(listen_socket_);
    listen_socket_ = -1;
  }

  if (accept_thread_.joinable()) {
    accept_thread_.join();
  }

  // 等待所有客户端线程退出
  {
    // client_threads_ 只在 AcceptLoop 中写入，这里只读
    for (auto& t : client_threads_) {
      if (t.joinable()) t.join();
    }
  }

  std::cout << "[ModbusServer] 已停止" << std::endl;
}

// =============================================================================
// Accept 循环
// =============================================================================

void ModbusServer::AcceptLoop() {
  while (running_.load()) {
    // 每次 accept 需要新的上下文
    modbus_t* listen_ctx = modbus_new_tcp("0.0.0.0",
                                          std::to_string(port_).c_str());
    if (listen_ctx == nullptr) {
      std::this_thread::sleep_for(std::chrono::seconds(1));
      continue;
    }

    modbus_set_slave(listen_ctx, 1);

    // 使用带超时的 listen
    int sock = modbus_tcp_listen(listen_ctx, 1);
    if (sock < 0) {
      modbus_free(listen_ctx);
      if (!running_.load()) break;
      std::this_thread::sleep_for(std::chrono::seconds(1));
      continue;
    }

    // 阻塞等待客户端连接
    int client_sock = modbus_tcp_accept(listen_ctx, &sock);
    modbus_free(listen_ctx);

    if (client_sock < 0) {
      if (running_.load()) {
        std::cerr << "[ModbusServer] accept 失败: "
                  << modbus_strerror(errno) << std::endl;
      }
      continue;
    }

    std::cout << "[ModbusServer] 新客户端连接 fd=" << client_sock << std::endl;

    // 启动客户端处理线程
    client_threads_.emplace_back(&ModbusServer::ClientHandler, this,
                                 client_sock);

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

void ModbusServer::ClientHandler(int client_socket) {
  modbus_t* ctx = modbus_new_tcp("0.0.0.0", std::to_string(port_).c_str());
  if (ctx == nullptr) {
    ::close(client_socket);
    return;
  }

  modbus_set_slave(ctx, 1);
  ctx->s = client_socket;  // 直接注入已 accept 的 socket

  // 分配 mapping
  const int kMaxRegisters = 65536;
  modbus_mapping_t* mapping = modbus_mapping_new(
      0, 0,                  // bits (coils)
      kMaxRegisters, 0);     // holding registers
  if (mapping == nullptr) {
    std::cerr << "[ModbusServer] modbus_mapping_new 失败" << std::endl;
    modbus_free(ctx);
    ::close(client_socket);
    return;
  }

  uint8_t query[MODBUS_TCP_MAX_ADU_LENGTH];

  while (running_.load()) {
    // 将最新寄存器值同步到 mapping
    register_map_.SyncToMapping(mapping);

    int rc = modbus_receive(ctx, query);
    if (rc < 0) {
      // 连接断开或错误
      if (errno == ECONNRESET || errno == ECONNABORTED || errno == EPIPE) {
        break;
      }
      // 超时，继续循环
      if (errno == ETIMEDOUT || errno == EAGAIN) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        continue;
      }
      break;
    }

    if (rc > 0) {
      // 处理请求
      modbus_reply(ctx, query, rc, mapping);

      // 回写被客户端修改的寄存器
      register_map_.SyncFromMapping(mapping);
    }
  }

  modbus_mapping_free(mapping);
  modbus_free(ctx);
  ::close(client_socket);

  std::cout << "[ModbusServer] 客户端断开 fd=" << client_socket << std::endl;
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
