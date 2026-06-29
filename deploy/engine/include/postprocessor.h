#pragma once

/**
 * @file postprocessor.h
 * @brief YOLO 后处理模块 — 输出解析 + NMS
 *
 * 解析 NPU 推理输出张量，执行置信度过滤、
 * 坐标解码和非极大值抑制 (NMS)。
 *
 * @author RK3588 Industrial Toolkit
 * @version 1.0.0
 */

#include <cstdint>
#include <string>
#include <vector>
#include <memory>

namespace rk3588 {
namespace engine {

/** @brief 单个检测结果 */
struct Detection {
  int class_id = -1;             ///< 类别 ID (0 ~ num_classes-1)
  std::string class_name;        ///< 类别名称
  float confidence = 0.0f;       ///< 置信度 (0.0 ~ 1.0)
  float x1 = 0.0f;               ///< 边界框左上角 X (归一化 0~1)
  float y1 = 0.0f;               ///< 边界框左上角 Y (归一化 0~1)
  float x2 = 0.0f;               ///< 边界框右下角 X (归一化 0~1)
  float y2 = 0.0f;               ///< 边界框右下角 Y (归一化 0~1)
};

/** @brief 后处理配置 */
struct PostprocessConfig {
  int input_width = 640;         ///< 模型输入宽度
  int input_height = 640;        ///< 模型输入高度
  int num_classes = 80;          ///< 类别数
  float conf_threshold = 0.5f;   ///< 置信度阈值
  float nms_threshold = 0.45f;   ///< NMS IoU 阈值
  bool use_class_agnostic_nms = false; ///< 是否类别无关 NMS
  std::vector<std::string> class_names; ///< 类别名称列表 (COCO 默认)
};

/** @brief YOLO 输出格式 */
enum class YoloFormat {
  YOLOV5,     ///< [x, y, w, h, obj_conf, cls_0, cls_1, ...]
  YOLOV8,     ///< [x, y, w, h, cls_0, cls_1, ...] (anchor-free)
  YOLOX,      ///< [x, y, w, h, obj_conf, cls_0, cls_1, ...] + decoupled head
};

/**
 * @class Postprocessor
 * @brief YOLO 模型后处理
 *
 * 支持 YOLOv5/v8/X 三种输出格式。
 * 执行: 置信度过滤 → 坐标解码 → NMS → Detection 列表
 *
 * 使用示例:
 * @code
 *   PostprocessConfig cfg;
 *   cfg.conf_threshold = 0.5f;
 *   cfg.nms_threshold = 0.45f;
 *   Postprocessor post(cfg);
 *   auto detections = post.Process(outputs, YoloFormat::YOLOV5);
 * @endcode
 */
class Postprocessor {
 public:
  /**
   * @brief 使用后处理配置构造
   * @param config 后处理参数
   */
  explicit Postprocessor(const PostprocessConfig& config);

  ~Postprocessor();

  // 禁止拷贝
  Postprocessor(const Postprocessor&) = delete;
  Postprocessor& operator=(const Postprocessor&) = delete;

  /**
   * @brief 执行后处理
   * @param outputs NPU 输出数据指针数组
   * @param output_sizes 各输出张量字节数
   * @param num_outputs 输出张量数量
   * @param format YOLO 输出格式
   * @return 检测结果列表
   */
  std::vector<Detection> Process(const float* const* outputs,
                                 const uint32_t* output_sizes,
                                 uint32_t num_outputs,
                                 YoloFormat format = YoloFormat::YOLOV5);

  /**
   * @brief 更新后处理配置
   * @param config 新配置
   */
  void UpdateConfig(const PostprocessConfig& config);

  /**
   * @brief 加载 COCO 80 类默认名称
   */
  static std::vector<std::string> DefaultCocoNames();

 private:
  /** @brief 解析 YOLOv5 输出格式 */
  std::vector<Detection> ParseYoloV5(const float* const* outputs,
                                     const uint32_t* output_sizes,
                                     uint32_t num_outputs);

  /** @brief 解析 YOLOv8 输出格式 */
  std::vector<Detection> ParseYoloV8(const float* const* outputs,
                                     const uint32_t* output_sizes,
                                     uint32_t num_outputs);

  /** @brief 解析 YOLOX 输出格式 */
  std::vector<Detection> ParseYoloX(const float* const* outputs,
                                    const uint32_t* output_sizes,
                                    uint32_t num_outputs);

  /** @brief 计算两个框的 IoU */
  static float ComputeIoU(const Detection& a, const Detection& b);

  /** @brief 非极大值抑制 */
  std::vector<Detection> ApplyNMS(std::vector<Detection>& detections);

  /** @brief 对 YOLO 坐标进行解码 (cx,cy,w,h → x1,y1,x2,y2) */
  void DecodeBoxes(std::vector<Detection>& detections, int grid_x, int grid_y);

  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace engine
}  // namespace rk3588
