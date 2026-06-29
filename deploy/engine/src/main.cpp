/**
 * @file main.cpp
 * @brief 推理引擎演示入口 — 单帧 + 实时摄像头推理 + RGA 硬件加速流水线
 *
 * 用法:
 *   ./demo_inference --config config/engine.yaml --model models/yolov5s.rknn --image test.jpg
 *   ./demo_inference --config config/engine.yaml --model models/yolov5s.rknn --camera /dev/video0
 *   ./demo_inference --rga-pipeline --device /dev/video0 --model models/yolov5s.rknn
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

// 简易命令行参数解析 (避免引入额外依赖)
struct CliArgs {
  std::string config_path = "config/engine.yaml";
  std::string model_path;
  std::string image_path;
  std::string camera_device;
  int run_frames = 100;
  bool show_help = false;
  bool verbose = false;
  bool use_rga_pipeline = false;
  bool list_devices = false;
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
    } else if (arg == "--list-devices") {
      args.list_devices = true;
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
  --list-devices          列出 V4L2 设备
  --verbose, -v           输出详细检测结果
  --help, -h              显示此帮助信息

示例:
  # 单图推理
  ./demo_inference --config config/engine.yaml --model models/yolov5s.rknn --image test.jpg

  # 摄像头实时推理 (100 帧)
  ./demo_inference --config config/engine.yaml --model models/yolov5s.rknn --camera /dev/video0 --frames 100

  # RGA 硬件加速流水线 (V4L2 + DMA-BUF 零拷贝)
  ./demo_inference --rga-pipeline --device /dev/video0 --model models/yolov5s.rknn --frames 100
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
  std::cout << "  最小延迟:    " << stats.min_latency_ms << " ms\n";
  std::cout << "  最大延迟:    " << stats.max_latency_ms << " ms\n";
  std::cout << "  预处理:      " << stats.preprocess_ms << " ms\n";
  std::cout << "  NPU 推理:    " << stats.inference_ms << " ms\n";
  std::cout << "  后处理:      " << stats.postprocess_ms << " ms\n";
  std::cout << "═══════════════════════════════════════════\n";
}

// 从文件读取图片数据
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

  // 默认分辨率 (实际应解析图片元数据)
  width = 640;
  height = 480;
  return data;
}

// RGA 流水线推理循环
void RunRgaPipeline(const CliArgs& args) {
  std::cout << "模式: RGA 硬件加速流水线\n";
  std::cout << "设备: " << args.camera_device << "\n";
  std::cout << "帧数: " << args.run_frames << "\n\n";

  // 配置 RGA 流水线
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

  // 初始化推理引擎
  rk3588::engine::Engine engine(args.config_path);
  if (!engine.LoadModel(args.model_path)) {
    std::cerr << "错误: 模型加载失败!" << std::endl;
    pipeline.Stop();
    return;
  }

  std::cout << "模型加载成功, 开始推理...\n";

  int frame_count = 0;
  for (int i = 0; i < args.run_frames; ++i) {
    // 采集 + RGA 转换 (NV12 → RGB, DMA-BUF 零拷贝)
    auto frame = pipeline.CaptureAndConvert();
    if (frame.dma_fd < 0) {
      continue;
    }

    // 此处 frame.dma_fd 可直接传给 rknn_set_io_mem 实现零拷贝推理
    // 简化演示: 使用 virt_addr 数据 (若可用)
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

  if (args.show_help || (args.model_path.empty() && !args.list_devices)) {
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

  // ── RGA 流水线模式 ──
  if (args.use_rga_pipeline) {
    if (args.camera_device.empty()) {
      std::cerr << "错误: --rga-pipeline 需要 --device 参数指定摄像头\n";
      return 1;
    }
    RunRgaPipeline(args);
    return 0;
  }

  // ── 初始化引擎 ──
  rk3588::engine::Engine engine(args.config_path);

  if (!engine.LoadModel(args.model_path)) {
    std::cerr << "错误: 模型加载失败!" << std::endl;
    return 1;
  }

  std::cout << "模型加载成功\n";

  // ── 单图推理模式 ──
  if (!args.image_path.empty()) {
    std::cout << "模式: 单图推理\n";
    std::cout << "图片: " << args.image_path << "\n";

    int width = 0, height = 0;
    auto img_data = LoadImage(args.image_path, width, height);
    if (img_data.empty()) {
      return 1;
    }

    auto detections = engine.Infer(img_data.data(), width, height, "BGR888");
    PrintDetections(detections, args.verbose);
    PrintStats(engine.GetStats());
  }
  // ── 摄像头实时推理模式 ──
  else if (!args.camera_device.empty()) {
    std::cout << "模式: 摄像头实时推理\n";
    std::cout << "设备: " << args.camera_device << "\n";
    std::cout << "帧数: " << args.run_frames << "\n\n";

    std::cout << "注意: 摄像头模式需要完整 V4L2 集成\n";
    std::cout << "建议使用 --rga-pipeline 开启硬件加速\n\n";

    // 模拟帧数据
    std::vector<uint8_t> dummy_frame(640 * 480 * 3, 128);
    int frame_count = 0;

    for (int i = 0; i < args.run_frames; ++i) {
      auto detections = engine.Infer(dummy_frame.data(), 640, 480, "BGR888");

      if (args.verbose && !detections.empty()) {
        std::cout << "帧 #" << i << ": ";
        PrintDetections(detections, false);
      }

      frame_count++;
      if (frame_count % 10 == 0) {
        std::cout << "." << std::flush;
      }
    }

    std::cout << "\n\n完成 " << frame_count << " 帧推理\n";
    PrintStats(engine.GetStats());
  }
  // ── 无输入源 ──
  else {
    std::cerr << "错误: 请指定 --image 或 --camera 或 --rga-pipeline\n";
    PrintUsage();
    return 1;
  }

  std::cout << "\n推理引擎正常退出\n";
  return 0;
}
