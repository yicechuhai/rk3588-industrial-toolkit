// =============================================================================
// pipeline_runner.cpp — RK3588 统一推理流水线主程序
// =============================================================================
// 整合: 摄像头采集 → RGA预处理 → NPU推理 → Modbus + OPC UA 双协议输出
//
// 用法:
//   pipeline_runner --engine config/engine.yaml \
//                   --modbus config/modbus_example.yaml \
//                   --opcua config/opcua_example.yaml \
//                   --camera rtsp://192.168.1.100:554/stream
//   pipeline_runner --engine config/engine.yaml --camera /dev/video0
//   pipeline_runner --engine config/engine.yaml --camera 0  (USB摄像头索引)
//
// 依赖: librknnrt, librga, libmodbus, open62541, OpenCV, yaml-cpp
// =============================================================================

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include <opencv2/opencv.hpp>
#include <opencv2/videoio.hpp>

// 引擎头文件
#include "engine.h"

// 协议头文件
#include "modbus_server.h"
#include "opcua_server.h"

// =============================================================================
// 全局状态（信号处理用）
// =============================================================================

namespace {

std::atomic<bool> g_running{true};

void SignalHandler(int signum) {
  std::cout << "\n[pipeline] 收到信号 " << signum << "，正在安全退出..." << std::endl;
  g_running.store(false);
}

// =============================================================================
// 辅助: 引擎 Detection → Modbus Detection (去归一化)
// =============================================================================

rk3588::protocol::modbus::Detection ConvertToModbus(
    const rk3588::engine::Detection& src, int frame_w, int frame_h) {
  rk3588::protocol::modbus::Detection dst;
  dst.class_id = src.class_id;
  dst.confidence = src.confidence;

  // 去归一化坐标 (0~1 → 像素坐标)
  dst.x1 = static_cast<int>(src.x1 * frame_w);
  dst.y1 = static_cast<int>(src.y1 * frame_h);
  dst.x2 = static_cast<int>(src.x2 * frame_w);
  dst.y2 = static_cast<int>(src.y2 * frame_h);
  dst.center_x = (dst.x1 + dst.x2) / 2;
  dst.center_y = (dst.y1 + dst.y2) / 2;
  dst.area = (dst.x2 - dst.x1) * (dst.y2 - dst.y1);

  return dst;
}

// =============================================================================
// 辅助: 引擎 Detection → OPC UA DetectionResult (x,y,w,h 格式)
// =============================================================================

rk3588::protocol::opcua::DetectionResult ConvertToOpcua(
    const rk3588::engine::Detection& src, int frame_w, int frame_h) {
  rk3588::protocol::opcua::DetectionResult dst;
  dst.class_id = static_cast<uint16_t>(src.class_id);
  dst.confidence = src.confidence;

  float x1 = src.x1 * frame_w;
  float y1 = src.y1 * frame_h;
  float x2 = src.x2 * frame_w;
  float y2 = src.y2 * frame_h;

  dst.bbox_x = x1;
  dst.bbox_y = y1;
  dst.bbox_w = x2 - x1;
  dst.bbox_h = y2 - y1;

  return dst;
}

// =============================================================================
// 辅助: 读取 NPU 温度 (通过 sysfs)
// =============================================================================

float ReadNpuTemperature() {
  std::ifstream temp_file("/sys/class/thermal/thermal_zone0/temp");
  if (!temp_file.is_open()) {
    temp_file.open("/sys/devices/virtual/thermal/thermal_zone0/temp");
  }
  if (temp_file.is_open()) {
    int temp_mc = 0;
    temp_file >> temp_mc;
    temp_file.close();
    return static_cast<float>(temp_mc) / 1000.0f;
  }
  return 0.0f;
}

// =============================================================================
// 辅助: 打印用法
// =============================================================================

void PrintUsage(const char* prog) {
  std::cout
      << "RK3588 工业推理流水线 v1.0\n"
      << "用法: " << prog << " [选项]\n"
      << "选项:\n"
      << "  --engine <path>    引擎 YAML 配置文件 (必需)\n"
      << "  --camera <source>  摄像头源: rtsp://... | /dev/video0 | 0 (必需)\n"
      << "  --modbus <path>    Modbus 寄存器映射 YAML (可选)\n"
      << "  --modbus-port <n>  Modbus TCP 端口 (默认 502)\n"
      << "  --opcua <path>     OPC UA 配置文件 YAML (可选)\n"
      << "  --opcua-port <n>   OPC UA 端口 (默认 4840)\n"
      << "  --no-modbus        禁用 Modbus 服务\n"
      << "  --no-opcua         禁用 OPC UA 服务\n"
      << "  --display          显示推理画面 (需要 X11/桌面环境)\n"
      << "  --help             显示此帮助\n"
      << std::endl;
}

}  // namespace

// =============================================================================
// 主函数
// =============================================================================

int main(int argc, char* argv[]) {
  // ── 参数解析 ──
  std::string engine_config;
  std::string camera_source;
  std::string modbus_config;
  std::string opcua_config;
  int modbus_port = 502;
  int opcua_port = 4840;
  bool enable_modbus = true;
  bool enable_opcua = true;
  bool enable_display = false;

  for (int i = 1; i < argc; ++i) {
    std::string arg(argv[i]);
    if (arg == "--engine" && i + 1 < argc) {
      engine_config = argv[++i];
    } else if (arg == "--camera" && i + 1 < argc) {
      camera_source = argv[++i];
    } else if (arg == "--modbus" && i + 1 < argc) {
      modbus_config = argv[++i];
    } else if (arg == "--modbus-port" && i + 1 < argc) {
      modbus_port = std::stoi(argv[++i]);
    } else if (arg == "--opcua" && i + 1 < argc) {
      opcua_config = argv[++i];
    } else if (arg == "--opcua-port" && i + 1 < argc) {
      opcua_port = std::stoi(argv[++i]);
    } else if (arg == "--no-modbus") {
      enable_modbus = false;
    } else if (arg == "--no-opcua") {
      enable_opcua = false;
    } else if (arg == "--display") {
      enable_display = true;
    } else if (arg == "--help" || arg == "-h") {
      PrintUsage(argv[0]);
      return 0;
    } else {
      std::cerr << "未知参数: " << arg << std::endl;
      PrintUsage(argv[0]);
      return 1;
    }
  }

  // ── 参数校验 ──
  if (engine_config.empty()) {
    std::cerr << "[pipeline] 错误: 必须指定 --engine 配置路径" << std::endl;
    PrintUsage(argv[0]);
    return 1;
  }
  if (camera_source.empty()) {
    std::cerr << "[pipeline] 错误: 必须指定 --camera 摄像头源" << std::endl;
    PrintUsage(argv[0]);
    return 1;
  }

  // ── 注册信号处理 ──
  std::signal(SIGINT, SignalHandler);
  std::signal(SIGTERM, SignalHandler);

  // ===========================================================================
  // 阶段 1: 初始化引擎
  // ===========================================================================
  std::cout << "[pipeline] ===== 阶段 1/4: 初始化推理引擎 =====" << std::endl;

  std::unique_ptr<rk3588::engine::Engine> engine;
  try {
    engine = std::make_unique<rk3588::engine::Engine>(engine_config);
    std::cout << "[pipeline] 引擎配置解析成功" << std::endl;
  } catch (const std::exception& e) {
    std::cerr << "[pipeline] 引擎初始化失败: " << e.what() << std::endl;
    return 1;
  }

  if (!engine->IsReady()) {
    std::cerr << "[pipeline] 模型加载失败或引擎未就绪" << std::endl;
    return 1;
  }

  std::cout << "[pipeline] 引擎就绪" << std::endl;

  // ===========================================================================
  // 阶段 2: 初始化摄像头
  // ===========================================================================
  std::cout << "[pipeline] ===== 阶段 2/4: 打开摄像头 =====" << std::endl;

  cv::VideoCapture cap;
  if (camera_source.find("rtsp://") == 0) {
    std::cout << "[pipeline] 打开 RTSP 流: " << camera_source << std::endl;
    cap.open(camera_source, cv::CAP_FFMPEG);
  } else if (camera_source.find("/dev/video") == 0) {
    std::cout << "[pipeline] 打开 V4L2 设备: " << camera_source << std::endl;
    cap.open(camera_source, cv::CAP_V4L2);
  } else {
    int cam_idx = std::stoi(camera_source);
    std::cout << "[pipeline] 打开摄像头索引: " << cam_idx << std::endl;
    cap.open(cam_idx, cv::CAP_V4L2);
  }

  if (!cap.isOpened()) {
    std::cerr << "[pipeline] 无法打开摄像头: " << camera_source << std::endl;
    return 1;
  }

  cap.set(cv::CAP_PROP_FOURCC, cv::VideoWriter::fourcc('N', 'V', '1', '2'));
  cap.set(cv::CAP_PROP_FRAME_WIDTH, 1920);
  cap.set(cv::CAP_PROP_FRAME_HEIGHT, 1080);
  cap.set(cv::CAP_PROP_FPS, 30);

  int cam_w = static_cast<int>(cap.get(cv::CAP_PROP_FRAME_WIDTH));
  int cam_h = static_cast<int>(cap.get(cv::CAP_PROP_FRAME_HEIGHT));
  double cam_fps = cap.get(cv::CAP_PROP_FPS);

  std::cout << "[pipeline] 摄像头: " << cam_w << "x" << cam_h
            << " @ " << cam_fps << " FPS" << std::endl;

  // ===========================================================================
  // 阶段 3: 初始化工业协议
  // ===========================================================================
  std::cout << "[pipeline] ===== 阶段 3/4: 启动工业协议服务 =====" << std::endl;

  // ── Modbus ──
  std::unique_ptr<rk3588::protocol::modbus::ModbusServer> modbus_server;
  if (enable_modbus) {
    modbus_server = std::make_unique<rk3588::protocol::modbus::ModbusServer>(modbus_port);

    if (!modbus_config.empty()) {
      if (!modbus_server->LoadRegisterMap(modbus_config)) {
        std::cerr << "[pipeline] 警告: Modbus 寄存器映射加载失败，使用默认映射" << std::endl;
      } else {
        std::cout << "[pipeline] Modbus 寄存器映射加载成功: " << modbus_config << std::endl;
      }
    }

    if (!modbus_server->Start()) {
      std::cerr << "[pipeline] 警告: Modbus 服务启动失败" << std::endl;
      modbus_server.reset();
    } else {
      std::cout << "[pipeline] Modbus TCP Server 已启动 (0.0.0.0:" << modbus_port << ")" << std::endl;
      modbus_server->SetStatus(1);
    }
  }

  // ── OPC UA ──
  std::unique_ptr<rk3588::protocol::opcua::OpcuaServer> opcua_server;
  if (enable_opcua) {
    opcua_server = std::make_unique<rk3588::protocol::opcua::OpcuaServer>(opcua_port);

    if (!opcua_server->Start()) {
      std::cerr << "[pipeline] 警告: OPC UA 服务启动失败" << std::endl;
      opcua_server.reset();
    } else {
      std::cout << "[pipeline] OPC UA Server 已启动 (0.0.0.0:" << opcua_port << ")" << std::endl;
    }
  }

  // ===========================================================================
  // 阶段 4: 主推理循环
  // ===========================================================================
  std::cout << "[pipeline] ===== 阶段 4/4: 进入推理循环 =====" << std::endl;
  std::cout << "[pipeline] 按 Ctrl+C 安全退出" << std::endl;

  cv::Mat frame;
  uint64_t frame_count = 0;
  auto loop_start = std::chrono::steady_clock::now();
  auto last_report = loop_start;

  while (g_running.load()) {
    // ── 采集帧 ──
    if (!cap.read(frame)) {
      std::cerr << "[pipeline] 读帧失败，尝试重连..." << std::endl;
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
      continue;
    }

    if (frame.empty()) {
      continue;
    }

    // ── 推理 ──
    auto detections = engine->Infer(
        frame.data,
        frame.cols,
        frame.rows,
        "BGR888");

    ++frame_count;

    // ── 更新 Modbus ──
    if (modbus_server && modbus_server->IsRunning()) {
      modbus_server->UpdateHeartbeat();

      std::vector<rk3588::protocol::modbus::Detection> modbus_dets;
      modbus_dets.reserve(detections.size());
      for (const auto& det : detections) {
        modbus_dets.push_back(ConvertToModbus(det, frame.cols, frame.rows));
      }
      modbus_server->UpdateDetections(modbus_dets);

      auto stats = engine->GetStats();
      modbus_server->SetFps(static_cast<float>(stats.fps));
      modbus_server->SetTemperature(ReadNpuTemperature());
    }

    // ── 更新 OPC UA ──
    if (opcua_server && opcua_server->IsRunning()) {
      std::vector<rk3588::protocol::opcua::DetectionResult> opcua_dets;
      opcua_dets.reserve(detections.size());
      for (const auto& det : detections) {
        opcua_dets.push_back(ConvertToOpcua(det, frame.cols, frame.rows));
      }
      opcua_server->UpdateDetectionResults(opcua_dets);

      auto stats = engine->GetStats();
      rk3588::protocol::opcua::SystemStatus sys_status;
      sys_status.inference_fps = static_cast<float>(stats.fps);
      sys_status.npu_temperature = ReadNpuTemperature();
      sys_status.cpu_usage = 0.0f;
      sys_status.memory_usage = 0.0f;
      opcua_server->UpdateSystemStatus(sys_status);
    }

    // ── 显示画面 (可选) ──
    if (enable_display) {
      for (const auto& det : detections) {
        int x1 = static_cast<int>(det.x1 * frame.cols);
        int y1 = static_cast<int>(det.y1 * frame.rows);
        int x2 = static_cast<int>(det.x2 * frame.cols);
        int y2 = static_cast<int>(det.y2 * frame.rows);

        cv::rectangle(frame, cv::Point(x1, y1), cv::Point(x2, y2),
                      cv::Scalar(0, 255, 0), 2);
        cv::putText(frame,
                    det.class_name + " " + std::to_string(det.confidence).substr(0, 4),
                    cv::Point(x1, y1 - 5),
                    cv::FONT_HERSHEY_SIMPLEX, 0.5,
                    cv::Scalar(0, 255, 0), 1);
      }
      cv::imshow("RK3588 Pipeline", frame);
      if (cv::waitKey(1) == 27) {
        g_running.store(false);
      }
    }

    // ── 定期性能报告 (每5秒) ──
    auto now = std::chrono::steady_clock::now();
    auto elapsed = std::chrono::duration<double>(now - last_report).count();
    if (elapsed >= 5.0) {
      auto stats = engine->GetStats();
      double total_elapsed = std::chrono::duration<double>(now - loop_start).count();
      double avg_fps = static_cast<double>(frame_count) / total_elapsed;

      std::cout << "[pipeline] 帧数: " << frame_count
                << " | FPS: " << stats.fps
                << " | 平均FPS: " << avg_fps
                << " | 延迟: " << stats.avg_latency_ms << "ms"
                << " | NPU温度: " << ReadNpuTemperature() << "°C"
                << " | 检测数: " << detections.size()
                << std::endl;

      last_report = now;
    }
  }

  // ===========================================================================
  // 清理
  // ===========================================================================
  std::cout << "\n[pipeline] ===== 正在安全关闭 =====" << std::endl;

  cap.release();
  cv::destroyAllWindows();

  if (modbus_server) {
    modbus_server->SetStatus(0);
    modbus_server->Stop();
    std::cout << "[pipeline] Modbus 服务已停止" << std::endl;
  }

  if (opcua_server) {
    opcua_server->Stop();
    std::cout << "[pipeline] OPC UA 服务已停止" << std::endl;
  }

  auto final_stats = engine->GetStats();
  std::cout << "\n[pipeline] ===== 最终统计 =====" << std::endl;
  std::cout << "  总帧数:     " << frame_count << std::endl;
  std::cout << "  平均FPS:    " << final_stats.fps << std::endl;
  std::cout << "  平均延迟:   " << final_stats.avg_latency_ms << " ms" << std::endl;
  std::cout << "  最小延迟:   " << final_stats.min_latency_ms << " ms" << std::endl;
  std::cout << "  最大延迟:   " << final_stats.max_latency_ms << " ms" << std::endl;
  std::cout << "[pipeline] 程序正常退出" << std::endl;

  return 0;
}
