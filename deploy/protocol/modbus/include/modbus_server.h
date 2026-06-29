// =============================================================================
// Modbus TCP Server — RK3588 工业中间件
// 将 NPU 推理结果暴露为 Modbus 保持寄存器，供 PLC/SCADA 读取
// =============================================================================

#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include <modbus.h>

namespace rk3588 {
namespace protocol {
namespace modbus {

// =============================================================================
// Detection — 检测结果结构体
// =============================================================================
struct Detection {
  int class_id = 0;
  float confidence = 0.0F;
  int x1 = 0;
  int y1 = 0;
  int x2 = 0;
  int y2 = 0;
  int center_x = 0;
  int center_y = 0;
  int area = 0;
};

// =============================================================================
// RegisterEntry — 单个寄存器描述
// =============================================================================
struct RegisterEntry {
  uint16_t address = 0;
  std::string name;
  std::string type = "uint16";
  std::string desc;
  uint16_t default_value = 0;
};

// =============================================================================
// RegisterMap — 寄存器地址映射与共享存储
// =============================================================================
class RegisterMap {
 public:
  RegisterMap();
  ~RegisterMap() = default;

  RegisterMap(const RegisterMap&) = delete;
  RegisterMap& operator=(const RegisterMap&) = delete;

  bool LoadFromYaml(const std::string& yaml_path);
  void SetMaxObjects(int n) { max_objects_ = n; }
  int max_objects() const { return max_objects_; }

  void WriteRegister(uint16_t addr, uint16_t value);
  uint16_t ReadRegister(uint16_t addr) const;

  bool WriteByName(const std::string& name, uint16_t value);
  uint16_t ReadByName(const std::string& name) const;

  void UpdateDetections(const std::vector<Detection>& detections);
  void UpdateSystemStatus(uint16_t heartbeat, uint16_t status,
                          uint32_t frame_counter, float fps, float temp_c);

  void SyncToMapping(modbus_mapping_t* mapping) const;
  void SyncFromMapping(const modbus_mapping_t* mapping);

 private:
  void BuildNameMap();
  void ClearObjectRegisters();

  mutable std::mutex mutex_;
  std::unordered_map<uint16_t, uint16_t> registers_;
  std::unordered_map<std::string, uint16_t> name_to_addr_;
  std::vector<RegisterEntry> entries_;

  int max_objects_ = 20;
  int obj_stride_ = 6;
  bool name_map_dirty_ = true;

  uint16_t addr_sys_base_ = 0x0000;
  uint16_t addr_summary_base_ = 0x0010;
  uint16_t addr_object_base_ = 0x0030;
};

// =============================================================================
// ModbusServer — Modbus TCP Server
// =============================================================================
class ModbusServer {
 public:
  explicit ModbusServer(int port = 502);
  ~ModbusServer();

  ModbusServer(const ModbusServer&) = delete;
  ModbusServer& operator=(const ModbusServer&) = delete;

  bool Start();
  void Stop();
  bool IsRunning() const { return running_.load(); }

  void SetHoldingRegister(uint16_t addr, uint16_t value);
  uint16_t GetHoldingRegister(uint16_t addr) const;
  void SetCoil(uint16_t addr, bool value);
  bool GetCoil(uint16_t addr) const;

  void UpdateDetections(const std::vector<Detection>& detections);
  void UpdateHeartbeat();
  void SetFps(float fps);
  void SetTemperature(float temp_c);
  void SetStatus(uint16_t status);

  bool LoadRegisterMap(const std::string& yaml_path);
  RegisterMap& register_map() { return register_map_; }
  const RegisterMap& register_map() const { return register_map_; }

 private:
  void AcceptLoop();
  void ClientHandler(int client_socket);

  int port_;
  int listen_socket_;
  std::atomic<bool> running_;
  std::thread accept_thread_;
  std::vector<std::thread> client_threads_;

  RegisterMap register_map_;

  std::atomic<uint16_t> heartbeat_{0};
  std::atomic<uint32_t> frame_counter_{0};
  std::atomic<float> fps_{0.0F};
  std::atomic<float> temperature_{0.0F};
  std::atomic<uint16_t> status_{0};

  mutable std::mutex coil_mutex_;
  std::unordered_map<uint16_t, bool> coils_;
};

}  // namespace modbus
}  // namespace protocol
}  // namespace rk3588
