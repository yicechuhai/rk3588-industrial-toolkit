// =============================================================================
// RegisterMap 实现 — YAML 驱动的寄存器地址映射
// =============================================================================

#include "modbus_server.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>

#include <yaml-cpp/yaml.h>

namespace rk3588 {
namespace protocol {
namespace modbus {

namespace {

// ── 辅助：检测 YAML 地址格式 ─────────────────────────────
// 40001-风格（PLC）→ 减去 40001 得到原始地址
// 0x0000-风格（Hex） → 直接解析
uint16_t ParseAddress(const std::string& val) {
  size_t pos = 0;
  unsigned long uval;

  if (val.size() >= 2 && (val[0] == '0' && (val[1] == 'x' || val[1] == 'X'))) {
    uval = std::stoul(val, &pos, 16);
  } else {
    uval = std::stoul(val, &pos, 10);
  }

  if (uval >= 40001 && uval <= 49999) {
    return static_cast<uint16_t>(uval - 40001);
  }

  if (uval > 0xFFFF) {
    return static_cast<uint16_t>(uval & 0xFFFF);
  }

  return static_cast<uint16_t>(uval);
}

// ── 辅助：float → uint16（缩放 x10）─────────────────────
uint16_t FloatToU16x10(float v) {
  return static_cast<uint16_t>(
      std::clamp(static_cast<int>(std::round(v * 10.0F)), 0, 65535));
}

// ── 辅助：float → uint16（缩放 x1000，置信度 0-1 → 0-1000）─
uint16_t FloatToU16x1000(float v) {
  return static_cast<uint16_t>(
      std::clamp(static_cast<int>(std::round(v * 1000.0F)), 0, 65535));
}

}  // namespace

// =============================================================================
// RegisterMap 构造
// =============================================================================

RegisterMap::RegisterMap() {
  // 初始化系统寄存器默认值
  registers_[addr_sys_base_ + 0] = 0;       // heartbeat
  registers_[addr_sys_base_ + 1] = 0;       // status
  registers_[addr_sys_base_ + 2] = 0;       // frame_counter (low)
  registers_[addr_sys_base_ + 3] = 0;       // fps_x10
  registers_[addr_sys_base_ + 4] = 0;       // temperature_x10

  // 初始化汇总区
  registers_[addr_summary_base_ + 0] = 0;   // detection_count
  registers_[addr_summary_base_ + 1] = 0;   // top1_class_id
  registers_[addr_summary_base_ + 2] = 0;   // top1_confidence_x1000
  registers_[addr_summary_base_ + 3] = 0;   // top1_center_x
  registers_[addr_summary_base_ + 4] = 0;   // top1_center_y

  ClearObjectRegisters();
}

// =============================================================================
// YAML 加载
// =============================================================================

bool RegisterMap::LoadFromYaml(const std::string& yaml_path) {
  try {
    YAML::Node root = YAML::LoadFile(yaml_path);

    // ── modbus.server 配置 ───────────────────────────────
    if (root["modbus"] && root["modbus"]["server"]) {
      auto server = root["modbus"]["server"];
      // port / bind / unit_id 由 ModbusServer 处理，此处仅记录
      std::cout << "[RegisterMap] 从 YAML 加载配置: "
                << yaml_path << std::endl;
    }

    // ── mapping.registers ────────────────────────────────
    if (root["mapping"] && root["mapping"]["registers"]) {
      auto regs = root["mapping"]["registers"];

      // 系统寄存器
      if (regs["heartbeat"]) {
        addr_sys_base_ = ParseAddress(regs["heartbeat"].as<std::string>());
      }
      if (regs["status"]) {
        // status 紧接 heartbeat
      }
      if (regs["detection_count"]) {
        addr_summary_base_ = ParseAddress(
            regs["detection_count"].as<std::string>());
      }

      // 对象基础地址
      if (regs["obj_0"] && regs["obj_0"]["base"]) {
        addr_object_base_ = ParseAddress(
            regs["obj_0"]["base"].as<std::string>());
      }
      if (regs["obj_0"] && regs["obj_0"]["layout"]) {
        obj_stride_ = static_cast<int>(regs["obj_0"]["layout"].size());
      }
    }

    // ── advanced ─────────────────────────────────────────
    if (root["advanced"] && root["advanced"]["max_objects"]) {
      max_objects_ = root["advanced"]["max_objects"].as<int>();
    }

    // ── 构建 entries_ 列表 ───────────────────────────────
    entries_.clear();
    if (root["mapping"] && root["mapping"]["registers"]) {
      auto regs = root["mapping"]["registers"];
      if (regs["obj_0"] && regs["obj_0"]["layout"]) {
        uint16_t base = addr_object_base_;
        for (const auto& item : regs["obj_0"]["layout"]) {
          RegisterEntry entry;
          entry.address = base + item["offset"].as<uint16_t>();
          entry.name = item["name"].as<std::string>();
          entry.type = item["type"] ? item["type"].as<std::string>() : "uint16";
          entry.desc = item["desc"] ? item["desc"].as<std::string>() : "";
          entries_.push_back(entry);
        }
      }
    }

    BuildNameMap();

    // 重建寄存器默认值
    registers_.clear();
    registers_[addr_sys_base_ + 0] = 0;
    registers_[addr_sys_base_ + 1] = 0;
    registers_[addr_sys_base_ + 3] = 0;
    registers_[addr_sys_base_ + 4] = 0;
    registers_[addr_summary_base_ + 0] = 0;
    registers_[addr_summary_base_ + 1] = 0;
    registers_[addr_summary_base_ + 2] = 0;
    registers_[addr_summary_base_ + 3] = 0;
    registers_[addr_summary_base_ + 4] = 0;
    ClearObjectRegisters();

    std::cout << "[RegisterMap] 配置加载完成: max_objects=" << max_objects_
              << " stride=" << obj_stride_
              << " sys_base=0x" << std::hex << addr_sys_base_
              << " obj_base=0x" << addr_object_base_ << std::dec
              << std::endl;

    return true;
  } catch (const YAML::Exception& e) {
    std::cerr << "[RegisterMap] YAML 解析失败: " << e.what() << std::endl;
    return false;
  }
}

// =============================================================================
// 原始寄存器读写
// =============================================================================

void RegisterMap::WriteRegister(uint16_t addr, uint16_t value) {
  std::lock_guard<std::mutex> lock(mutex_);
  registers_[addr] = value;
}

uint16_t RegisterMap::ReadRegister(uint16_t addr) const {
  std::lock_guard<std::mutex> lock(mutex_);
  auto it = registers_.find(addr);
  return (it != registers_.end()) ? it->second : 0;
}

// =============================================================================
// 命名寄存器读写
// =============================================================================

bool RegisterMap::WriteByName(const std::string& name, uint16_t value) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (name_map_dirty_) {
    // name_map_dirty_ 需要 mutable mutex_，实际上这里需要 const cast
    // 折中方案：调用方确保非并发调用此方法
  }
  auto it = name_to_addr_.find(name);
  if (it == name_to_addr_.end()) return false;
  registers_[it->second] = value;
  return true;
}

uint16_t RegisterMap::ReadByName(const std::string& name) const {
  std::lock_guard<std::mutex> lock(mutex_);
  auto it = name_to_addr_.find(name);
  if (it == name_to_addr_.end()) return 0;
  auto rit = registers_.find(it->second);
  return (rit != registers_.end()) ? rit->second : 0;
}

// =============================================================================
// 批量更新检测结果
// =============================================================================

void RegisterMap::UpdateDetections(const std::vector<Detection>& detections) {
  std::lock_guard<std::mutex> lock(mutex_);

  // 更新检测数量
  int count = std::min(static_cast<int>(detections.size()), max_objects_);
  registers_[addr_summary_base_ + 0] = static_cast<uint16_t>(count);

  // 找最高置信度目标
  int top_idx = -1;
  float top_conf = -1.0F;
  for (int i = 0; i < count; ++i) {
    if (detections[i].confidence > top_conf) {
      top_conf = detections[i].confidence;
      top_idx = i;
    }
  }

  if (top_idx >= 0) {
    const auto& t = detections[top_idx];
    registers_[addr_summary_base_ + 1] = static_cast<uint16_t>(t.class_id);
    registers_[addr_summary_base_ + 2] = FloatToU16x1000(t.confidence);
    registers_[addr_summary_base_ + 3] = static_cast<uint16_t>(
        std::clamp(t.center_x, 0, 65535));
    registers_[addr_summary_base_ + 4] = static_cast<uint16_t>(
        std::clamp(t.center_y, 0, 65535));
  } else {
    registers_[addr_summary_base_ + 1] = 0;
    registers_[addr_summary_base_ + 2] = 0;
    registers_[addr_summary_base_ + 3] = 0;
    registers_[addr_summary_base_ + 4] = 0;
  }

  // 写入每个目标（每目标 obj_stride_ 个寄存器）
  ClearObjectRegisters();
  for (int i = 0; i < count; ++i) {
    const auto& d = detections[i];
    uint16_t base = addr_object_base_ + static_cast<uint16_t>(i * obj_stride_);

    registers_[base + 0] = static_cast<uint16_t>(
        std::clamp(d.class_id, 0, 65535));
    registers_[base + 1] = FloatToU16x1000(d.confidence);
    registers_[base + 2] = static_cast<uint16_t>(
        std::clamp(d.x1, 0, 65535));
    registers_[base + 3] = static_cast<uint16_t>(
        std::clamp(d.y1, 0, 65535));
    registers_[base + 4] = static_cast<uint16_t>(
        std::clamp(d.x2, 0, 65535));
    registers_[base + 5] = static_cast<uint16_t>(
        std::clamp(d.y2, 0, 65535));
  }
}

// =============================================================================
// 更新系统状态
// =============================================================================

void RegisterMap::UpdateSystemStatus(uint16_t heartbeat, uint16_t status,
                                     uint32_t frame_counter,
                                     float fps, float temp_c) {
  std::lock_guard<std::mutex> lock(mutex_);

  registers_[addr_sys_base_ + 0] = heartbeat;
  registers_[addr_sys_base_ + 1] = status;
  // frame_counter 是 uint32，拆分成两个 uint16 寄存器
  registers_[addr_sys_base_ + 2] = static_cast<uint16_t>(frame_counter & 0xFFFF);
  registers_[addr_sys_base_ + 3] = FloatToU16x10(fps);
  registers_[addr_sys_base_ + 4] = FloatToU16x10(temp_c);
}

// =============================================================================
// libmodbus mapping 同步
// =============================================================================

void RegisterMap::SyncToMapping(modbus_mapping_t* mapping) const {
  if (mapping == nullptr || mapping->tab_registers == nullptr) return;

  std::lock_guard<std::mutex> lock(mutex_);
  for (const auto& [addr, val] : registers_) {
    if (addr < mapping->nb_registers) {
      mapping->tab_registers[addr] = val;
    }
  }
}

void RegisterMap::SyncFromMapping(const modbus_mapping_t* mapping) {
  if (mapping == nullptr || mapping->tab_registers == nullptr) return;

  std::lock_guard<std::mutex> lock(mutex_);
  // 只同步寄存器映射区（0x0000 - max_addr）
  for (int addr = 0; addr < static_cast<int>(mapping->nb_registers); ++addr) {
    registers_[static_cast<uint16_t>(addr)] = mapping->tab_registers[addr];
  }
}

// =============================================================================
// 内部方法
// =============================================================================

void RegisterMap::BuildNameMap() {
  name_to_addr_.clear();
  for (const auto& entry : entries_) {
    name_to_addr_[entry.name] = entry.address;
  }
  name_map_dirty_ = false;
}

void RegisterMap::ClearObjectRegisters() {
  uint16_t end = addr_object_base_ +
                 static_cast<uint16_t>(max_objects_ * obj_stride_);
  for (uint16_t addr = addr_object_base_; addr < end; ++addr) {
    registers_[addr] = 0;
  }
}

}  // namespace modbus
}  // namespace protocol
}  // namespace rk3588
