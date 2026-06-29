#pragma once

/**
 * @file engine.h
 * @brief RK3588 零拷贝推理引擎 — 主引擎类
 *
 * 提供模型加载、单帧推理、性能统计等核心接口。
 * 内部使用 DMA-BUF 共享内存实现零拷贝数据路径。
 *
 * @author RK3588 Industrial Toolkit
 * @version 1.0.0
 */

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "model_loader.h"
#include "preprocessor.h"
#include "postprocessor.h"

namespace rk3588 {
namespace engine {

/** @brief 推理性能统计 */
struct InferenceStats {
  double fps = 0.0;               ///< 当前帧率
  double avg_latency_ms = 0.0;    ///< 平均推理延迟 (ms)
  double min_latency_ms = 0.0;    ///< 最小推理延迟 (ms)
  double max_latency_ms = 0.0;    ///< 最大推理延迟 (ms)
  uint64_t total_frames = 0;      ///< 累计推理帧数
  double preprocess_ms = 0.0;     ///< 预处理耗时 (ms)
  double inference_ms = 0.0;      ///< NPU 推理耗时 (ms)
  double postprocess_ms = 0.0;    ///< 后处理耗时 (ms)
};

/**
 * @class Engine
 * @brief 零拷贝推理引擎主类
 *
 * 整合模型加载、RGA 预处理、NPU 推理、后处理全流程。
 * 通过 DMA-BUF 在 RGA → NPU 之间共享内存，消除 CPU 拷贝。
 *
 * 使用示例:
 * @code
 *   Engine engine("config/engine.yaml");
 *   engine.LoadModel("models/yolov5s.rknn");
 *   auto detections = engine.Infer(frame_data, width, height, format);
 *   auto stats = engine.GetStats();
 * @endcode
 */
class Engine {
 public:
  /**
   * @brief 从 YAML 配置文件构造引擎
   * @param config_path YAML 配置文件路径
   * @throws std::runtime_error 配置文件解析失败时抛出
   */
  explicit Engine(const std::string& config_path);

  ~Engine();

  // 禁止拷贝和移动
  Engine(const Engine&) = delete;
  Engine& operator=(const Engine&) = delete;
  Engine(Engine&&) = delete;
  Engine& operator=(Engine&&) = delete;

  /**
   * @brief 加载 RKNN 模型
   * @param model_path .rknn 模型文件路径
   * @return 成功返回 true
   */
  bool LoadModel(const std::string& model_path);

  /**
   * @brief 单帧推理
   * @param frame_data 原始帧数据指针 (NV12 / RGB / BGR)
   * @param width 帧宽度
   * @param height 帧高度
   * @param format 像素格式: "NV12", "RGB888", "BGR888"
   * @return 检测结果列表
   */
  std::vector<Detection> Infer(const uint8_t* frame_data, int width, int height,
                               const std::string& format);

  /**
   * @brief 获取推理性能统计
   * @return InferenceStats 结构体
   */
  InferenceStats GetStats() const;

  /**
   * @brief 重置性能统计计数器
   */
  void ResetStats();

  /**
   * @brief 检查引擎是否已就绪（模型已加载）
   * @return 已就绪返回 true
   */
  bool IsReady() const;

 private:
  /** @brief 解析 YAML 配置文件 */
  void ParseConfig(const std::string& config_path);

  /** @brief 分配 DMA-BUF 输入/输出张量 */
  bool AllocateDmaBufTensors();

  /** @brief 释放 DMA-BUF 资源 */
  void ReleaseDmaBufTensors();

  /** @brief 更新性能统计 */
  void UpdateStats(double preprocess_ms, double inference_ms, double postprocess_ms);

  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace engine
}  // namespace rk3588
