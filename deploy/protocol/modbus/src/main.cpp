// =============================================================================
// main.cpp — Modbus TCP Server 独立运行示例
// =============================================================================
// 用法：
//   modbus_server --config config/modbus_example.yaml
//   modbus_server --port 502
// =============================================================================

#include <chrono>
#include <csignal>
#include <cstdlib>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

#include "modbus_server.h"

namespace {

rk3588::protocol::modbus::ModbusServer* g_server = nullptr;

void SignalHandler(int /*signum*/) {
  std::cout << "\n[main] 收到退出信号，正在停止服务器..." << std::endl;
  if (g_server != nullptr) {
    g_server->Stop();
  }
}

void PrintUsage(const char* prog) {
  std::cout << "用法: " << prog << " [选项]\n"
            << "选项:\n"
            << "  --config <path>   寄存器映射 YAML 配置文件\n"
            << "  --port <port>     Modbus TCP 端口 (默认 502)\n"
            << "  --help            显示此帮助\n"
            << std::endl;
}

}  // namespace

int main(int argc, char* argv[]) {
  int port = 502;
  std::string config_path;

  // ── 解析命令行参数 ────────────────────────────────────
  for (int i = 1; i < argc; ++i) {
    std::string arg(argv[i]);
    if (arg == "--help" || arg == "-h") {
      PrintUsage(argv[0]);
      return 0;
    } else if (arg == "--port" && i + 1 < argc) {
      port = std::stoi(argv[++i]);
    } else if (arg == "--config" && i + 1 < argc) {
      config_path = argv[++i];
    } else {
      std::cerr << "未知参数: " << arg << std::endl;
      PrintUsage(argv[0]);
      return 1;
    }
  }

  // ── 注册信号处理 ──────────────────────────────────────
  signal(SIGINT, SignalHandler);
  signal(SIGTERM, SignalHandler);

  // ── 创建服务器 ────────────────────────────────────────
  rk3588::protocol::modbus::ModbusServer server(port);
  g_server = &server;

  // 加载寄存器映射配置
  if (!config_path.empty()) {
    if (!server.LoadRegisterMap(config_path)) {
      std::cerr << "[main] 无法加载配置文件: " << config_path << std::endl;
      std::cerr << "[main] 将使用默认寄存器映射" << std::endl;
    }
  }

  // ── 启动服务器 ────────────────────────────────────────
  if (!server.Start()) {
    std::cerr << "[main] 服务器启动失败" << std::endl;
    return 1;
  }

  std::cout << "[main] Modbus TCP Server 运行中，按 Ctrl+C 退出" << std::endl;
  std::cout << "[main] 监听地址: 0.0.0.0:" << port << std::endl;

  // ── 模拟检测数据更新 ──────────────────────────────────
  server.SetStatus(1);  // 运行中
  int tick = 0;

  while (server.IsRunning()) {
    server.UpdateHeartbeat();

    // 每 5 秒生成模拟检测结果
    if (tick % 50 == 0) {
      std::vector<rk3588::protocol::modbus::Detection> detections;

      // 模拟 3 个目标
      rk3588::protocol::modbus::Detection d1;
      d1.class_id = 0;  // person
      d1.confidence = 0.92F;
      d1.x1 = 100;
      d1.y1 = 50;
      d1.x2 = 300;
      d1.y2 = 400;
      d1.center_x = 200;
      d1.center_y = 225;
      d1.area = (300 - 100) * (400 - 50);
      detections.push_back(d1);

      rk3588::protocol::modbus::Detection d2;
      d2.class_id = 1;  // car
      d2.confidence = 0.87F;
      d2.x1 = 500;
      d2.y1 = 100;
      d2.x2 = 700;
      d2.y2 = 350;
      d2.center_x = 600;
      d2.center_y = 225;
      d2.area = (700 - 500) * (350 - 100);
      detections.push_back(d2);

      rk3588::protocol::modbus::Detection d3;
      d3.class_id = 3;  // box
      d3.confidence = 0.65F;
      d3.x1 = 800;
      d3.y1 = 200;
      d3.x2 = 880;
      d3.y2 = 280;
      d3.center_x = 840;
      d3.center_y = 240;
      d3.area = (880 - 800) * (280 - 200);
      detections.push_back(d3);

      server.UpdateDetections(detections);
      std::cout << "[main] 更新 " << detections.size()
                << " 条模拟检测结果" << std::endl;
    }

    // 模拟 FPS 和温度
    server.SetFps(25.0F + (tick % 10) * 0.5F);
    server.SetTemperature(55.0F + (tick % 20) * 0.3F);

    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    ++tick;
  }

  g_server = nullptr;
  std::cout << "[main] 程序退出" << std::endl;
  return 0;
}
