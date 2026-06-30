// =============================================================================
// pipeline_runner.cpp — RK3588 统一推理流水线主程序
// =============================================================================
// 用法:
//   pipeline_runner --engine config/engine.yaml --camera /dev/video0
//   pipeline_runner --engine config.yaml --camera rtsp://ip:554/stream --display

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

#include "engine.h"
#include "modbus_server.h"
#include "opcua_server.h"

namespace {

std::atomic<bool> g_running{true};

void SignalHandler(int signum) {
  std::cout << "\n[pipeline] Received signal " << signum << ", shutting down..." << std::endl;
  g_running.store(false);
}

rk3588::protocol::modbus::Detection ConvertToModbus(
    const rk3588::engine::Detection& src, int frame_w, int frame_h) {
  rk3588::protocol::modbus::Detection dst;
  dst.class_id = src.class_id;
  dst.confidence = src.confidence;
  dst.x1 = static_cast<int>(src.x1 * frame_w);
  dst.y1 = static_cast<int>(src.y1 * frame_h);
  dst.x2 = static_cast<int>(src.x2 * frame_w);
  dst.y2 = static_cast<int>(src.y2 * frame_h);
  dst.center_x = (dst.x1 + dst.x2) / 2;
  dst.center_y = (dst.y1 + dst.y2) / 2;
  dst.area = (dst.x2 - dst.x1) * (dst.y2 - dst.y1);
  return dst;
}

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

void PrintUsage(const char* prog) {
  std::cout
      << "RK3588 Industrial Pipeline v1.0\n"
      << "Usage: " << prog << " [options]\n"
      << "Options:\n"
      << "  --engine <path>    Engine YAML config (required)\n"
      << "  --camera <source>  Camera source: rtsp://... | /dev/video0 | 0 (required)\n"
      << "  --modbus <path>    Modbus register map YAML\n"
      << "  --modbus-port <n>  Modbus TCP port (default 502)\n"
      << "  --opcua <path>     OPC UA config YAML\n"
      << "  --opcua-port <n>   OPC UA port (default 4840)\n"
      << "  --no-modbus        Disable Modbus\n"
      << "  --no-opcua         Disable OPC UA\n"
      << "  --display          Show inference display\n"
      << "  --help             Show this help\n"
      << std::endl;
}

}  // namespace

int main(int argc, char* argv[]) {
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
      std::cerr << "Unknown arg: " << arg << std::endl;
      PrintUsage(argv[0]);
      return 1;
    }
  }

  if (engine_config.empty() || camera_source.empty()) {
    PrintUsage(argv[0]);
    return 1;
  }

  std::signal(SIGINT, SignalHandler);
  std::signal(SIGTERM, SignalHandler);

  // Phase 1: Init engine
  std::cout << "[pipeline] Phase 1/4: Init engine..." << std::endl;
  std::unique_ptr<rk3588::engine::Engine> engine;
  try {
    engine = std::make_unique<rk3588::engine::Engine>(engine_config);
    std::cout << "[pipeline] Config parsed" << std::endl;
  } catch (const std::exception& e) {
    std::cerr << "[pipeline] Engine init failed: " << e.what() << std::endl;
    return 1;
  }

  if (!engine->LoadModel("")) {
    std::cerr << "[pipeline] Model load failed" << std::endl;
    return 1;
  }

  if (!engine->IsReady()) {
    std::cerr << "[pipeline] Engine not ready" << std::endl;
    return 1;
  }
  std::cout << "[pipeline] Engine ready" << std::endl;

  // Phase 2: Open camera
  std::cout << "[pipeline] Phase 2/4: Open camera..." << std::endl;
    cv::VideoCapture cap;
  bool cp = false;
  
  if (camera_source.find("rtsp://") == 0) {
    std::cout << "[pipeline] Opening RTSP: " << camera_source << std::endl;
    cp = cap.open(camera_source, cv::CAP_FFMPEG);
  } else if (camera_source.find("/dev/video") == 0) {
    std::cout << "[pipeline] Opening V4L2: " << camera_source << std::endl;
    cp = cap.open(camera_source, cv::CAP_V4L2);
  } else {
    int cam_idx = std::stoi(camera_source);
    std::cout << "[pipeline] Opening idx " << cam_idx << " (V4L2 first)..." << std::endl;
    cp = cap.open(cam_idx, cv::CAP_V4L2);
    if (!cp) {
      std::cout << "[pipeline] Trying CAP_ANY..." << std::endl;
      cp = cap.open(cam_idx, cv::CAP_ANY);
    }
  }

  if (!cp || !cap.isOpened()) {
    std::cerr << "[pipeline] Camera failed" << std::endl;
    return 1;
  }

  int cam_w = static_cast<int>(cap.get(cv::CAP_PROP_FRAME_WIDTH));
  int cam_h = static_cast<int>(cap.get(cv::CAP_PROP_FRAME_HEIGHT));
  double cam_fps = cap.get(cv::CAP_PROP_FPS);
  std::cout << "[pipeline] Camera: " << cam_w << "x" << cam_h << " @ " << cam_fps << " FPS" << std::endl;

  // Phase 3: Start protocol servers
  std::cout << "[pipeline] Phase 3/4: Start protocols..." << std::endl;
  std::unique_ptr<rk3588::protocol::modbus::ModbusServer> modbus_server;
  if (enable_modbus) {
    modbus_server = std::make_unique<rk3588::protocol::modbus::ModbusServer>(modbus_port);
    if (!modbus_config.empty()) {
      modbus_server->LoadRegisterMap(modbus_config);
    }
    if (modbus_server->Start()) {
      modbus_server->SetStatus(1);
      std::cout << "[pipeline] Modbus TCP on ::" << modbus_port << std::endl;
    } else {
      modbus_server.reset();
    }
  }

  std::unique_ptr<rk3588::protocol::opcua::OpcuaServer> opcua_server;
  if (enable_opcua) {
    opcua_server = std::make_unique<rk3588::protocol::opcua::OpcuaServer>(opcua_port);
    if (opcua_server->Start()) {
      std::cout << "[pipeline] OPC UA on ::" << opcua_port << std::endl;
    } else {
      opcua_server.reset();
    }
  }

  // Phase 4: Inference loop
  std::cout << "[pipeline] Phase 4/4: Inference loop (Ctrl+C to stop)" << std::endl;
  cv::Mat frame;
  uint64_t frame_count = 0;
  auto loop_start = std::chrono::steady_clock::now();
  auto last_report = loop_start;

  while (g_running.load()) {
    if (!cap.read(frame) || frame.empty()) {
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
      continue;
    }

    auto detections = engine->Infer(frame.data, frame.cols, frame.rows, "BGR888");
    ++frame_count;

    if (modbus_server && modbus_server->IsRunning()) {
      modbus_server->UpdateHeartbeat();
      std::vector<rk3588::protocol::modbus::Detection> mdets;
      mdets.reserve(detections.size());
      for (const auto& d : detections) mdets.push_back(ConvertToModbus(d, frame.cols, frame.rows));
      modbus_server->UpdateDetections(mdets);
      auto st = engine->GetStats();
      modbus_server->SetFps(static_cast<float>(st.fps));
      modbus_server->SetTemperature(ReadNpuTemperature());
    }

    if (opcua_server && opcua_server->IsRunning()) {
      std::vector<rk3588::protocol::opcua::DetectionResult> odets;
      odets.reserve(detections.size());
      for (const auto& d : detections) odets.push_back(ConvertToOpcua(d, frame.cols, frame.rows));
      opcua_server->UpdateDetectionResults(odets);
      auto st = engine->GetStats();
      rk3588::protocol::opcua::SystemStatus ss;
      ss.inference_fps = static_cast<float>(st.fps);
      ss.npu_temperature = ReadNpuTemperature();
      opcua_server->UpdateSystemStatus(ss);
    }

    if (enable_display) {
      for (const auto& d : detections) {
        int x1 = static_cast<int>(d.x1 * frame.cols);
        int y1 = static_cast<int>(d.y1 * frame.rows);
        int x2 = static_cast<int>(d.x2 * frame.cols);
        int y2 = static_cast<int>(d.y2 * frame.rows);
        cv::rectangle(frame, cv::Point(x1, y1), cv::Point(x2, y2), cv::Scalar(0, 255, 0), 2);
      }
      cv::imshow("RK3588 Pipeline", frame);
      if (cv::waitKey(1) == 27) g_running.store(false);
    }

    auto now = std::chrono::steady_clock::now();
    if (std::chrono::duration<double>(now - last_report).count() >= 5.0) {
      auto st = engine->GetStats();
      // stats period
      std::cout << "[pipeline] Frames:" << frame_count << " FPS:" << st.fps
                << " Latency:" << st.avg_latency_ms << "ms"
                << " Temp:" << ReadNpuTemperature() << "C"
                << " Dets:" << detections.size() << std::endl;
      last_report = now;
    }
  }

  // Cleanup
  std::cout << "\n[pipeline] Shutting down..." << std::endl;
  cap.release();
  if (modbus_server) { modbus_server->SetStatus(0); modbus_server->Stop(); }
  if (opcua_server) { opcua_server->Stop(); }
  auto st = engine->GetStats();
  std::cout << "[pipeline] Frames:" << frame_count << " AvgFPS:" << st.fps << " AvgLat:" << st.avg_latency_ms << "ms" << std::endl;
  return 0;
}
