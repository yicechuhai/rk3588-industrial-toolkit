#include "opcua_server.h"

#include <csignal>
#include <cstdlib>
#include <iostream>
#include <thread>
#include <vector>

#include <yaml-cpp/yaml.h>

namespace {

rk3588::protocol::opcua::OpcuaServer* g_server = nullptr;

void SignalHandler(int /*signum*/) {
  std::cout << "\n[OPCUA] 收到中断信号，正在关闭..." << std::endl;
  if (g_server != nullptr) {
    g_server->Stop();
  }
  std::exit(0);
}

}  // namespace

int main(int argc, char* argv[]) {
  std::string config_path = "config/opcua_example.yaml";
  if (argc > 1) {
    config_path = argv[1];
  }

  uint16_t port = 4840;
  std::string username;
  std::string password;

  // 加载 YAML 配置
  try {
    YAML::Node config = YAML::LoadFile(config_path);

    if (config["opcua"] && config["opcua"]["server"]) {
      auto server_cfg = config["opcua"]["server"];

      if (server_cfg["port"]) {
        port = server_cfg["port"].as<uint16_t>();
      }

      if (server_cfg["auth"]) {
        if (server_cfg["auth"]["username"]) {
          username = server_cfg["auth"]["username"].as<std::string>();
        }
        if (server_cfg["auth"]["password"]) {
          password = server_cfg["auth"]["password"].as<std::string>();
        }
      }
    }

    std::cout << "[OPCUA] 配置加载成功: " << config_path << std::endl;
  } catch (const YAML::Exception& e) {
    std::cerr << "[OPCUA] YAML 配置解析失败: " << e.what() << std::endl;
    std::cerr << "[OPCUA] 使用默认配置 (port=" << port << ")" << std::endl;
  }

  // 注册信号处理
  std::signal(SIGINT, SignalHandler);
  std::signal(SIGTERM, SignalHandler);

  // 创建并启动服务器
  rk3588::protocol::opcua::OpcuaServer server(port);

  if (!username.empty()) {
    server.SetAuthCredentials(username, password);
  }

  g_server = &server;

  if (!server.Start()) {
    std::cerr << "[OPCUA] 服务器启动失败" << std::endl;
    return 1;
  }

  std::cout << "[OPCUA] OPC UA Server 运行中，按 Ctrl+C 退出..." << std::endl;

  // 模拟数据更新（演示用）
  rk3588::protocol::opcua::SystemStatus status;
  status.cpu_usage = 35.2F;
  status.memory_usage = 62.8F;
  status.npu_temperature = 48.5F;
  status.inference_fps = 29.7F;

  std::vector<rk3588::protocol::opcua::DetectionResult> detections;
  rk3588::protocol::opcua::DetectionResult det;
  det.class_id = 0;
  det.confidence = 0.95F;
  det.bbox_x = 320.0F;
  det.bbox_y = 240.0F;
  det.bbox_w = 120.0F;
  det.bbox_h = 180.0F;
  detections.push_back(det);

  int tick = 0;
  while (server.IsRunning()) {
    std::this_thread::sleep_for(std::chrono::seconds(2));

    // 周期性更新模拟数据
    status.cpu_usage = 30.0F + static_cast<float>(tick % 20);
    status.inference_fps = 28.0F + static_cast<float>(tick % 5);
    server.UpdateSystemStatus(status);

    detections[0].confidence = 0.90F + static_cast<float>(tick % 10) * 0.01F;
    server.UpdateDetectionResults(detections);

    ++tick;
  }

  return 0;
}
