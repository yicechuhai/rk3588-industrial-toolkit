#include "opcua_server.h"

#include <open62541/server.h>
#include <open62541/server_config_default.h>

#include <chrono>
#include <cstring>
#include <iostream>

namespace rk3588 {
namespace protocol {
namespace opcua {

namespace {

void WriteFloatValue(UA_Server* server, UA_NodeId node_id, float value) {
  UA_Variant v;
  UA_Variant_init(&v);
  UA_Float* f = UA_Float_new();
  *f = value;
  UA_Variant_setScalarCopy(&v, f, &UA_TYPES[UA_TYPES_FLOAT]);
  UA_Float_delete(f);
  UA_Server_writeValue(server, node_id, v);
  UA_Variant_clear(&v);
}

void WriteUInt16Value(UA_Server* server, UA_NodeId node_id, uint16_t value) {
  UA_Variant v;
  UA_Variant_init(&v);
  UA_UInt16* u = UA_UInt16_new();
  *u = value;
  UA_Variant_setScalarCopy(&v, u, &UA_TYPES[UA_TYPES_UINT16]);
  UA_UInt16_delete(u);
  UA_Server_writeValue(server, node_id, v);
  UA_Variant_clear(&v);
}

}  // namespace

OpcuaServer::OpcuaServer(uint16_t port)
    : port_(port),
      server_name_("RK3588_AI_Vision_Server"),
      application_uri_("urn:rk3588:industrial:vision") {
  UA_NodeId_init(&cpu_usage_node_);
  UA_NodeId_init(&memory_usage_node_);
  UA_NodeId_init(&npu_temp_node_);
  UA_NodeId_init(&fps_node_);
  UA_NodeId_init(&detection_count_node_);
  UA_NodeId_init(&model_name_node_);
  UA_NodeId_init(&input_resolution_node_);
}

OpcuaServer::~OpcuaServer() {
  Stop();
  if (config_ != nullptr) {
    UA_ServerConfig_clean(config_);
    UA_ServerConfig_delete(config_);
    config_ = nullptr;
  }
}

void OpcuaServer::SetupServerConfig() {
  config_ = UA_ServerConfig_new_minimal(port_, nullptr);

  config_->applicationDescription.applicationName =
      UA_LOCALIZEDTEXT(const_cast<char*>("en-US"),
                       const_cast<char*>(server_name_.c_str()));
  config_->applicationDescription.applicationUri =
      UA_STRING_ALLOC(application_uri_.c_str());

  // 安全策略：None（基础版）
  config_->securityMode = UA_MESSAGESECURITYMODE_NONE;

  // 用户名密码认证
  if (!auth_username_.empty() && !auth_password_.empty()) {
    config_->accessControl.clear(&config_->accessControl);

    UA_UsernamePasswordLogin login;
    UA_UsernamePasswordLogin_init(&login);
    login.username = UA_STRING_ALLOC(auth_username_.c_str());
    login.password = UA_STRING_ALLOC(auth_password_.c_str());

    UA_AccessControl_default(
        config_, true,
        &config_->applicationDescription.applicationUri,
        &config_->securityPolicies[0].policyUri,
        1, &login);

    UA_String_clear(&login.username);
    UA_String_clear(&login.password);
  } else {
    UA_AccessControl_default(config_, false, nullptr, nullptr, 0, nullptr);
  }
}

bool OpcuaServer::Start() {
  if (running_.load()) {
    return true;
  }

  SetupServerConfig();

  server_ = UA_Server_newWithConfig(config_);
  if (server_ == nullptr) {
    std::cerr << "[OPCUA] 创建服务器实例失败" << std::endl;
    return false;
  }

  BuildNodeModel();

  running_.store(true);
  server_thread_ = std::make_unique<std::thread>(
      &OpcuaServer::ServerLoop, this);

  std::cout << "[OPCUA] 服务器已启动 opc.tcp://0.0.0.0:"
            << port_ << std::endl;
  return true;
}

void OpcuaServer::Stop() {
  if (!running_.load()) {
    return;
  }

  running_.store(false);

  if (server_ != nullptr) {
    UA_Server_run_shutdown(server_);
  }

  if (server_thread_ != nullptr && server_thread_->joinable()) {
    server_thread_->join();
  }

  if (server_ != nullptr) {
    UA_Server_delete(server_);
    server_ = nullptr;
  }

  std::cout << "[OPCUA] 服务器已停止" << std::endl;
}

void OpcuaServer::ServerLoop() {
  UA_Server_run_startup(server_);

  while (running_.load()) {
    UA_Server_run_iterate(server_, true);
  }

  UA_Server_run_shutdown(server_);
}

bool OpcuaServer::AddVariable(const std::string& node_id,
                               const UA_Variant& value) {
  (void)node_id;
  (void)value;
  return false;
}

void OpcuaServer::UpdateDetectionResults(
    const std::vector<DetectionResult>& detections) {
  std::lock_guard<std::mutex> lock(mutex_);

  if (server_ == nullptr) {
    return;
  }

  size_t count = detections.size();
  if (count > static_cast<size_t>(kMaxDetections)) {
    count = kMaxDetections;
  }

  // 写入 DetectionCount
  UA_UInt32 det_count = static_cast<UA_UInt32>(count);
  UA_Variant count_val;
  UA_Variant_init(&count_val);
  UA_Variant_setScalarCopy(&count_val, &det_count,
                           &UA_TYPES[UA_TYPES_UINT32]);
  UA_Server_writeValue(server_, detection_count_node_, count_val);
  UA_Variant_clear(&count_val);

  // 写入每个检测槽位
  for (size_t i = 0; i < static_cast<size_t>(kMaxDetections); ++i) {
    const auto& slot = detection_slots_[i];

    if (i < count) {
      const auto& det = detections[i];
      WriteUInt16Value(server_, slot.class_id, det.class_id);
      WriteFloatValue(server_, slot.confidence, det.confidence);
      WriteFloatValue(server_, slot.bbox_x, det.bbox_x);
      WriteFloatValue(server_, slot.bbox_y, det.bbox_y);
      WriteFloatValue(server_, slot.bbox_w, det.bbox_w);
      WriteFloatValue(server_, slot.bbox_h, det.bbox_h);
    } else {
      // 清空未使用槽位
      WriteUInt16Value(server_, slot.class_id, 0);
      WriteFloatValue(server_, slot.confidence, 0.0F);
      WriteFloatValue(server_, slot.bbox_x, 0.0F);
      WriteFloatValue(server_, slot.bbox_y, 0.0F);
      WriteFloatValue(server_, slot.bbox_w, 0.0F);
      WriteFloatValue(server_, slot.bbox_h, 0.0F);
    }
  }
}

void OpcuaServer::UpdateSystemStatus(const SystemStatus& status) {
  std::lock_guard<std::mutex> lock(mutex_);

  if (server_ == nullptr) {
    return;
  }

  WriteFloatValue(server_, cpu_usage_node_, status.cpu_usage);
  WriteFloatValue(server_, memory_usage_node_, status.memory_usage);
  WriteFloatValue(server_, npu_temp_node_, status.npu_temperature);
  WriteFloatValue(server_, fps_node_, status.inference_fps);
}

void OpcuaServer::SetAuthCredentials(const std::string& username,
                                      const std::string& password) {
  auth_username_ = username;
  auth_password_ = password;
}

}  // namespace opcua
}  // namespace protocol
}  // namespace rk3588
