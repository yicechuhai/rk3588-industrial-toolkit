/**
 * @file engine.cpp
 * @brief 零拷贝推理引擎主类实现
 */

#include "engine.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <fstream>
#include <sstream>
#include <stdexcept>

// YAML 解析 — 使用 yaml-cpp 库
#include "yaml-cpp/yaml.h"

namespace rk3588 {
namespace engine {

// ============================================================================
// PIMPL 实现结构
// ============================================================================

struct Engine::Impl {
  // 子模块
  std::unique_ptr<ModelLoader> model_loader;
  std::unique_ptr<Preprocessor> preprocessor;
  std::unique_ptr<Postprocessor> postprocessor;

  // 配置参数
  std::string config_path;
  std::string model_path;
  int input_width = 640;
  int input_height = 640;
  int num_classes = 80;
  float conf_threshold = 0.5f;
  float nms_threshold = 0.45f;
  NpuConfig npu_config;
  PreprocessConfig pre_config;
  PostprocessConfig post_config;
  YoloFormat yolo_format = YoloFormat::YOLOV5;

  // 状态
  bool model_loaded = false;
  bool ready = false;

  // DMA-BUF 内存
  struct DmaBufMem {
    int fd = -1;
    void* virt_addr = nullptr;
    uint32_t size = 0;
    rknn_tensor_mem* mem = nullptr;
  };
  std::vector<DmaBufMem> input_mems;
  std::vector<DmaBufMem> output_mems;

  // 性能统计
  InferenceStats stats;
  std::chrono::steady_clock::time_point last_stats_reset;
  std::vector<double> latency_history;
  static constexpr size_t kMaxLatencySamples = 100;
};

// ============================================================================
// 构造 / 析构
// ============================================================================

Engine::Engine(const std::string& config_path)
    : impl_(std::make_unique<Impl>()) {
  impl_->config_path = config_path;
  impl_->last_stats_reset = std::chrono::steady_clock::now();
  ParseConfig(config_path);
}

Engine::~Engine() {
  ReleaseDmaBufTensors();
}

// ============================================================================
// 配置解析 (YAML)
// ============================================================================

void Engine::ParseConfig(const std::string& config_path) {
  try {
    YAML::Node root = YAML::LoadFile(config_path);

    // ── 模型配置 ──
    if (root["model"]) {
      auto model = root["model"];
      if (model["path"]) {
        impl_->model_path = model["path"].as<std::string>();
      }
      if (model["input_size"] && model["input_size"].IsSequence() &&
          model["input_size"].size() >= 2) {
        impl_->input_width = model["input_size"][0].as<int>();
        impl_->input_height = model["input_size"][1].as<int>();
      }
      if (model["num_classes"]) {
        impl_->num_classes = model["num_classes"].as<int>();
      }
      if (model["conf_threshold"]) {
        impl_->conf_threshold = model["conf_threshold"].as<float>();
      }
      if (model["nms_threshold"]) {
        impl_->nms_threshold = model["nms_threshold"].as<float>();
      }
      if (model["format"]) {
        std::string fmt = model["format"].as<std::string>();
        if (fmt == "yolov8") {
          impl_->yolo_format = YoloFormat::YOLOV8;
        } else if (fmt == "yolox") {
          impl_->yolo_format = YoloFormat::YOLOX;
        }
      }
    }

    // ── NPU 配置 ──
    if (root["npu"]) {
      auto npu = root["npu"];
      if (npu["core_mask"]) {
        impl_->npu_config.core_mask = npu["core_mask"].as<uint32_t>();
      }
      if (npu["frequency"]) {
        std::string freq = npu["frequency"].as<std::string>();
        if (freq != "auto") {
          impl_->npu_config.auto_freq = false;
          impl_->npu_config.freq_mhz = static_cast<uint32_t>(
              std::stoi(freq.substr(0, freq.find("MHz"))));
        }
      }
    }

    // ── 预处理配置 ──
    if (root["preprocess"]) {
      auto pre = root["preprocess"];
      impl_->pre_config.target_width = impl_->input_width;
      impl_->pre_config.target_height = impl_->input_height;
      if (pre["mean"] && pre["mean"].IsSequence() && pre["mean"].size() >= 3) {
        impl_->pre_config.mean = {
            pre["mean"][0].as<float>(),
            pre["mean"][1].as<float>(),
            pre["mean"][2].as<float>()
        };
      }
      if (pre["std"] && pre["std"].IsSequence() && pre["std"].size() >= 3) {
        impl_->pre_config.std = {
            pre["std"][0].as<float>(),
            pre["std"][1].as<float>(),
            pre["std"][2].as<float>()
        };
      }
      if (pre["letterbox"]) {
        impl_->pre_config.letterbox = pre["letterbox"].as<bool>();
      }
      if (pre["use_rga"]) {
        impl_->pre_config.use_rga = pre["use_rga"].as<bool>();
      }
    }

    // ── 后处理配置 ──
    impl_->post_config.input_width = impl_->input_width;
    impl_->post_config.input_height = impl_->input_height;
    impl_->post_config.num_classes = impl_->num_classes;
    impl_->post_config.conf_threshold = impl_->conf_threshold;
    impl_->post_config.nms_threshold = impl_->nms_threshold;
    impl_->post_config.class_names = Postprocessor::DefaultCocoNames();

  } catch (const YAML::Exception& e) {
    throw std::runtime_error("Failed to parse config YAML: " +
                             std::string(e.what()));
  }
}

// ============================================================================
// 模型加载
// ============================================================================

bool Engine::LoadModel(const std::string& model_path) {
  impl_->model_path = model_path;

  // 初始化子模块
  impl_->model_loader = std::make_unique<ModelLoader>();
  if (!impl_->model_loader->Load(model_path, impl_->npu_config)) {
    return false;
  }

  impl_->preprocessor = std::make_unique<Preprocessor>(impl_->pre_config);
  impl_->postprocessor = std::make_unique<Postprocessor>(impl_->post_config);

  // 分配 DMA-BUF 张量内存
  if (!AllocateDmaBufTensors()) {
    impl_->model_loader->Release();
    return false;
  }

  impl_->model_loaded = true;
  impl_->ready = true;
  return true;
}

// ============================================================================
// DMA-BUF 内存分配
// ============================================================================

bool Engine::AllocateDmaBufTensors() {
  if (!impl_->model_loader || !impl_->model_loader->IsLoaded()) {
    return false;
  }

  auto ctx = impl_->model_loader->GetContext();
  auto io_info = impl_->model_loader->GetIOInfo();

  // 分配输入 DMA-BUF 内存
  for (const auto& input : io_info.inputs) {
    rknn_tensor_mem* mem = rknn_create_memory(ctx, input.size);
    if (!mem) {
      ReleaseDmaBufTensors();
      return false;
    }

    // 将内存绑定为输入
    int ret = rknn_set_io_mem(ctx, mem, &input.attrs);
    if (ret < 0) {
      rknn_destroy_memory(ctx, mem);
      ReleaseDmaBufTensors();
      return false;
    }

    Impl::DmaBufMem buf_mem;
    buf_mem.mem = mem;
    buf_mem.virt_addr = mem->virt_addr;
    buf_mem.fd = mem->fd;
    buf_mem.size = mem->size;
    impl_->input_mems.push_back(buf_mem);
  }

  // 分配输出 DMA-BUF 内存
  for (const auto& output : io_info.outputs) {
    rknn_tensor_mem* mem = rknn_create_memory(ctx, output.size);
    if (!mem) {
      ReleaseDmaBufTensors();
      return false;
    }

    int ret = rknn_set_io_mem(ctx, mem, &output.attrs);
    if (ret < 0) {
      rknn_destroy_memory(ctx, mem);
      ReleaseDmaBufTensors();
      return false;
    }

    Impl::DmaBufMem buf_mem;
    buf_mem.mem = mem;
    buf_mem.virt_addr = mem->virt_addr;
    buf_mem.fd = mem->fd;
    buf_mem.size = mem->size;
    impl_->output_mems.push_back(buf_mem);
  }

  return true;
}

void Engine::ReleaseDmaBufTensors() {
  auto ctx = impl_->model_loader ? impl_->model_loader->GetContext() : nullptr;

  for (auto& mem : impl_->input_mems) {
    if (mem.mem && ctx) {
      rknn_destroy_memory(ctx, mem.mem);
      mem.mem = nullptr;
    }
  }
  impl_->input_mems.clear();

  for (auto& mem : impl_->output_mems) {
    if (mem.mem && ctx) {
      rknn_destroy_memory(ctx, mem.mem);
      mem.mem = nullptr;
    }
  }
  impl_->output_mems.clear();
}

// ============================================================================
// 推理
// ============================================================================

std::vector<Detection> Engine::Infer(const uint8_t* frame_data, int width,
                                     int height, const std::string& format) {
  if (!impl_->ready) {
    return {};
  }

  auto t_total_start = std::chrono::steady_clock::now();

  // ── 步骤 1: 预处理 (RGA 硬件加速) ──
  auto t_pre_start = std::chrono::steady_clock::now();

  PixelFormat pf = PixelFormat::NV12;
  if (format == "RGB888" || format == "RGB") {
    pf = PixelFormat::RGB888;
  } else if (format == "BGR888" || format == "BGR") {
    pf = PixelFormat::BGR888;
  }

  auto tensor = impl_->preprocessor->Process(frame_data, width, height, pf);

  auto t_pre_end = std::chrono::steady_clock::now();
  double pre_ms = std::chrono::duration<double, std::milli>(t_pre_end - t_pre_start).count();

  // ── 步骤 2: 拷贝预处理数据到 NPU 输入 DMA-BUF ──
  if (!impl_->input_mems.empty() && impl_->input_mems[0].virt_addr &&
      tensor.data && tensor.size > 0) {
    size_t copy_size = std::min(tensor.size,
                                impl_->input_mems[0].size);
    std::memcpy(impl_->input_mems[0].virt_addr, tensor.data, copy_size);

    // 刷新缓存以确保 NPU 可见 (DMA-BUF 场景)
    rknn_mem_sync(impl_->model_loader->GetContext(),
                  impl_->input_mems[0].mem, RKNN_MEM_SYNC_TO_DEVICE);
  }

  impl_->preprocessor->ReleaseTensor(const_cast<PreprocessedTensor&>(tensor));

  // ── 步骤 3: NPU 推理 ──
  auto t_infer_start = std::chrono::steady_clock::now();

  int ret = rknn_run(impl_->model_loader->GetContext(), nullptr);
  if (ret < 0) {
    return {};
  }

  // 同步输出 DMA-BUF (确保 CPU 可读)
  for (auto& out_mem : impl_->output_mems) {
    rknn_mem_sync(impl_->model_loader->GetContext(),
                  out_mem.mem, RKNN_MEM_SYNC_FROM_DEVICE);
  }

  auto t_infer_end = std::chrono::steady_clock::now();
  double infer_ms = std::chrono::duration<double, std::milli>(
      t_infer_end - t_infer_start).count();

  // ── 步骤 4: 后处理 ──
  auto t_post_start = std::chrono::steady_clock::now();

  std::vector<const float*> output_ptrs;
  std::vector<uint32_t> output_sizes;
  for (auto& out_mem : impl_->output_mems) {
    output_ptrs.push_back(static_cast<const float*>(out_mem.virt_addr));
    output_sizes.push_back(out_mem.size);
  }

  auto detections = impl_->postprocessor->Process(
      output_ptrs.data(), output_sizes.data(),
      static_cast<uint32_t>(output_ptrs.size()),
      impl_->yolo_format);

  auto t_post_end = std::chrono::steady_clock::now();
  double post_ms = std::chrono::duration<double, std::milli>(
      t_post_end - t_post_start).count();

  // ── 更新统计 ──
  UpdateStats(pre_ms, infer_ms, post_ms);

  return detections;
}

// ============================================================================
// 性能统计
// ============================================================================

void Engine::UpdateStats(double preprocess_ms, double inference_ms,
                         double postprocess_ms) {
  double total_ms = preprocess_ms + inference_ms + postprocess_ms;

  impl_->stats.total_frames++;
  impl_->stats.preprocess_ms = preprocess_ms;
  impl_->stats.inference_ms = inference_ms;
  impl_->stats.postprocess_ms = postprocess_ms;

  // 维护延迟历史 (滑动窗口)
  impl_->latency_history.push_back(total_ms);
  if (impl_->latency_history.size() > Impl::kMaxLatencySamples) {
    impl_->latency_history.erase(impl_->latency_history.begin());
  }

  // 计算统计值
  if (!impl_->latency_history.empty()) {
    double sum = 0.0;
    impl_->stats.min_latency_ms = impl_->latency_history[0];
    impl_->stats.max_latency_ms = impl_->latency_history[0];
    for (double v : impl_->latency_history) {
      sum += v;
      impl_->stats.min_latency_ms = std::min(impl_->stats.min_latency_ms, v);
      impl_->stats.max_latency_ms = std::max(impl_->stats.max_latency_ms, v);
    }
    impl_->stats.avg_latency_ms = sum / impl_->latency_history.size();
    impl_->stats.fps = (impl_->stats.avg_latency_ms > 0.0)
                           ? (1000.0 / impl_->stats.avg_latency_ms)
                           : 0.0;
  }
}

InferenceStats Engine::GetStats() const {
  return impl_->stats;
}

void Engine::ResetStats() {
  impl_->stats = InferenceStats{};
  impl_->latency_history.clear();
  impl_->last_stats_reset = std::chrono::steady_clock::now();
}

bool Engine::IsReady() const {
  return impl_->ready;
}

}  // namespace engine
}  // namespace rk3588
