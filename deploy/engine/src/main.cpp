/**
 * @file main.cpp
 * @brief 推理引擎演示入口 — 单帧 + 实时摄像头推理 + RGA 硬件加速流水线
 *
 * @author RK3588 Industrial Toolkit
 * @version 1.0.0
 */

#include <chrono>
#include <cstring>
#include <fstream>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

#include "engine.h"
#include "rga_pipeline.h"

struct CliArgs {
  std::string config_path = "config/engine.yaml";
  std::string model_path;
  std::string image_path;
  std::string camera_device;
  int run_frames = 100;
  bool show_help = false;
  bool verbose = false;
  bool use_rga_pipeline = false;
};

CliArgs ParseArgs(int argc, char* argv[]) {
  CliArgs args;
  for (int i = 1; i < argc; ++i) {
    std::string arg = argv[i];
    if (arg == "--config" && i + 1 < argc) {
      args.config_path = argv[++i];
    } else if (arg == "--model" && i + 1 < argc) {
      args.model_path = argv[++i];
    } else if (arg == "--image" && i + 1 < argc) {
      args.image_path = argv[++i];
    } else if (arg == "--camera" && i + 1 < argc) {
      args.camera_device = argv[++i];
    } else if (arg == "--frames" && i + 1 < argc) {
      args.run_frames = std::stoi(argv[++i]);
    } else if (arg == "--rga-pipeline") {
      args.use_rga_pipeline = true;
    } else if (arg == "--verbose" || arg == "-v") {
      args.verbose = true;
    } else if (arg == "--help" || arg == "-h") {
      args.show_help = true;
    }
  }
  return args;
}

void PrintUsage() {
  std::cout << R"(
RK3588 零拷贝推理引擎 — 演示程序
==================================

用法:
  ./demo_inference [选项]

选项:
  --config <path>         YAML 配置文件路径 (默认: config/engine.yaml)
  --model <path>          .rknn 模型文件路径
  --image <path>          单张图片推理模式
  --camera <device>       实时摄像头推理模式 (e.g. /dev/video0)
  --rga-pipeline          使用 RGA 硬件加速流水线 (V4L2 + im2d 零拷贝)
  --frames <N>            摄像头模式下运行的帧数 (默认: 100)
  --verbose, -v           输出详细检测结果
  --help, -h              显示此帮助信息

)" << std::endl;
}

void PrintDetections(const std::vector<rk3588::engine::Detection>& detections,
                     bool verbose) {
  if (detections.empty()) {
    std::cout << "  (未检测到目标)" << std::endl;
    return;
  }
  std::cout << "  检测到 " << detections.size() << " 个目标:\n";
  for (const auto& det : detections) {
    if (verbose) {
      std::cout << "    [" << det.class_name << "] "
                << "置信度: " << (det.confidence * 100.0f) << "% "
                << "框: (" << det.x1 << ", " << det.y1 << ", "
                << det.x2 << ", " << det.y2 << ")\n";
    } else {
      std::cout << "    " << det.class_name
                << " (" << static_cast<int>(det.confidence * 100) << "%)\n";
    }
  }
}

void PrintStats(const rk3588::engine::InferenceStats& stats) {
  std::cout << "\n═══════════════════════════════════════════\n";
  std::cout << "推理性能统计\n";
  std::cout << "───────────────────────────────────────────\n";
  std::cout << "  总帧数:      " << stats.total_frames << "\n";
  std::cout << "  帧率:        " << stats.fps << " FPS\n";
  std::cout << "  平均延迟:    " << stats.avg_latency_ms << " ms\n";
  std::cout << "  预处理:      " << stats.preprocess_ms << " ms\n";
  std::cout << "  NPU 推理:    " << stats.inference_ms << " ms\n";
  std::cout << "  后处理:      " << stats.postprocess_ms << " ms\n";
  std::cout << "═══════════════════════════════════════════\n";
}

std::vector<uint8_t> LoadImage(const std::string& path, int& width, int& height) {
  std::ifstream file(path, std::ios::binary | std::ios::ate);
  if (!file.is_open()) {
    std::cerr << "无法打开图片: " << path << std::endl;
    return {};
  }
  std::streamsize size = file.tellg();
  file.seekg(0, std::ios::beg);
  std::vector<uint8_t> data(size);
  file.read(reinterpret_cast<char*>(data.data()), size);
  file.close();
  width = 640;
  height = 480;
  return data;
}

void RunRgaPipeline(const CliArgs& args) {
  std::cout << "模式: RGA 硬件加速流水线\n";
  std::cout << "设备: " << args.camera_device << "\n";
  std::cout << "帧数: " << args.run_frames << "\n\n";

  rk3588::engine::CameraConfig cam_cfg;
  cam_cfg.device = args.camera_device;
  cam_cfg.width = 1920;
  cam_cfg.height = 1080;
  cam_cfg.fps = 30;
  cam_cfg.use_dmabuf = true;

  rk3588::engine::RgaConvertConfig rga_cfg;
  rga_cfg.dst_width = 640;
  rga_cfg.dst_height = 640;
  rga_cfg.letterbox = true;

  rk3588::engine::RgaPipeline pipeline(cam_cfg, rga_cfg);
  if (!pipeline.Init()) {
    std::cerr << "错误: RGA 流水线初始化失败!" << std::endl;
    return;
  }

  rk3588::engine::Engine engine(args.config_path);
  if (!engine.LoadModel(args.model_path)) {
    std::cerr << "错误: 模型加载失败!" << std::endl;
    pipeline.Stop();
    return;
  }

  std::cout << "模型加载成功, 开始推理...\n";

  int frame_count = 0;
  for (int i = 0; i < args.run_frames; ++i) {
    auto frame = pipeline.CaptureAndConvert();
    if (frame.dma_fd < 0) {
      continue;
    }
    if (frame.virt_addr) {
      auto detections = engine.Infer(
          static_cast<const uint8_t*>(frame.virt_addr),
          frame.width, frame.height, "RGB888");
      if (args.verbose && !detections.empty()) {
        std::cout << "帧 #" << i << ": ";
        PrintDetections(detections, false);
      }
    }
    pipeline.ReleaseFrame(frame);
    frame_count++;
    if (frame_count % 10 == 0) {
      std::cout << "." << std::flush;
    }
  }

  pipeline.Stop();
  std::cout << "\n\n完成 " << frame_count << " 帧推理\n";
  PrintStats(engine.GetStats());
}

int main(int argc, char* argv[]) {
  auto args = ParseArgs(argc, argv);
  if (args.show_help || args.model_path.empty()) {
    PrintUsage();
    return args.show_help ? 0 : 1;
  }

  std::cout << "RK3588 零拷贝推理引擎 v1.0.0\n";
  if (!args.config_path.empty()) {
    std::cout << "配置: " << args.config_path << "\n";
  }
  if (!args.model_path.empty()) {
    std::cout << "模型: " << args.model_path << "\n";
  }

  if (args.use_rga_pipeline) {
    if (args.camera_device.empty()) {
      std::cerr << "错误: --rga-pipeline 需要 --camera 参数\n";
      return 1;
    }
    RunRgaPipeline(args);
    return 0;
  }

  rk3588::engine::Engine engine(args.config_path);
  if (!engine.LoadModel(args.model_path)) {
    std::cerr << "错误: 模型加载失败!" << std::endl;
    return 1;
  }
  std::cout << "模型加载成功\n";

  if (!args.image_path.empty()) {
    std::cout << "模式: 单图推理\n";
    int width = 0, height = 0;
    auto img_data = LoadImage(args.image_path, width, height);
    if (img_data.empty()) return 1;
    auto detections = engine.Infer(img_data.data(), width, height, "BGR888");
    PrintDetections(detections, args.verbose);
    PrintStats(engine.GetStats());
  } else if (!args.camera_device.empty()) {
    std::cout << "模式: 摄像头实时推理\n";
    std::cout << "建议使用 --rga-pipeline 开启硬件加速\n\n";
    std::vector<uint8_t> dummy_frame(640 * 480 * 3, 128);
    int frame_count = 0;
    for (int i = 0; i < args.run_frames; ++i) {
      auto detections = engine.Infer(dummy_frame.data(), 640, 480, "BGR888");
      if (args.verbose && !detections.empty()) {
        std::cout << "帧 #" << i << ": ";
        PrintDetections(detections, false);
      }
      frame_count++;
      if (frame_count % 10 == 0) std::cout << "." << std::flush;
    }
    std::cout << "\n\n完成 " << frame_count << " 帧推理\n";
    PrintStats(engine.GetStats());
  } else {
    std::cerr << "错误: 请指定 --image 或 --camera 或 --rga-pipeline\n";
    PrintUsage();
    return 1;
  }

  std::cout << "\n推理引擎正常退出\n";
  return 0;
}
