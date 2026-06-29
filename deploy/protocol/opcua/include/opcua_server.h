#ifndef RK3588_PROTOCOL_OPCUA_SERVER_H_
#define RK3588_PROTOCOL_OPCUA_SERVER_H_

#include <open62541.h>
#include // open62541.h includes default config

#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace rk3588 {
namespace protocol {
namespace opcua {

struct DetectionResult {
  uint16_t class_id = 0;
  float confidence = 0.0F;
  float bbox_x = 0.0F;
  float bbox_y = 0.0F;
  float bbox_w = 0.0F;
  float bbox_h = 0.0F;
};

struct SystemStatus {
  float cpu_usage = 0.0F;
  float memory_usage = 0.0F;
  float npu_temperature = 0.0F;
  float inference_fps = 0.0F;
};

// 单个检测槽位的节点 ID 集合
struct DetectionSlotNodes {
  UA_NodeId class_id;
  UA_NodeId confidence;
  UA_NodeId bbox_x;
  UA_NodeId bbox_y;
  UA_NodeId bbox_w;
  UA_NodeId bbox_h;
};

class OpcuaServer {
 public:
  explicit OpcuaServer(uint16_t port = 4840);
  ~OpcuaServer();

  OpcuaServer(const OpcuaServer&) = delete;
  OpcuaServer& operator=(const OpcuaServer&) = delete;
  OpcuaServer(OpcuaServer&&) = delete;
  OpcuaServer& operator=(OpcuaServer&&) = delete;

  bool Start();
  void Stop();

  bool AddVariable(const std::string& node_id, const UA_Variant& value);
  void UpdateDetectionResults(const std::vector<DetectionResult>& detections);
  void UpdateSystemStatus(const SystemStatus& status);

  void SetAuthCredentials(const std::string& username,
                          const std::string& password);

  bool IsRunning() const { return running_.load(); }
  uint16_t Port() const { return port_; }

 private:
  void SetupServerConfig();
  void BuildNodeModel();
  void ServerLoop();

  void AddVariableNode(UA_NodeId parent, const char* name,
                       UA_UInt16 ns_idx, const UA_Variant& value,
                       UA_NodeId* out_node_id);

  void AddObjectFolder(UA_NodeId parent, const char* name,
                       UA_UInt16 ns_idx, UA_NodeId* out_node_id);

  uint16_t port_;
  std::string server_name_;
  std::string application_uri_;

  UA_Server* server_ = nullptr;
  UA_ServerConfig* config_ = nullptr;

  std::unique_ptr<std::thread> server_thread_;
  std::atomic<bool> running_{false};

  std::string auth_username_;
  std::string auth_password_;

  // 节点 ID 缓存 —— 用于快速更新
  UA_NodeId cpu_usage_node_;
  UA_NodeId memory_usage_node_;
  UA_NodeId npu_temp_node_;
  UA_NodeId fps_node_;
  UA_NodeId detection_count_node_;
  UA_NodeId model_name_node_;
  UA_NodeId input_resolution_node_;

  // 检测槽位节点缓存
  std::vector<DetectionSlotNodes> detection_slots_;

  mutable std::mutex mutex_;

  static constexpr int kMaxDetections = 20;
};

}  // namespace opcua
}  // namespace protocol
}  // namespace rk3588

#endif  // RK3588_PROTOCOL_OPCUA_SERVER_H_
