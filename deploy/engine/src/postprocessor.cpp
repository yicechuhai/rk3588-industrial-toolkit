/**
 * @file postprocessor.cpp
 * @brief YOLO 后处理实现 — 输出解析、坐标解码、NMS
 *
 * 支持的格式:
 *   - YOLOv5:  85 通道 / anchor (x,y,w,h,obj_conf + 80 classes)
 *   - YOLOv8:  84 通道 / anchor-free  (x,y,w,h + 80 classes)
 *   - YOLOX:   decoupled head (cls_output, reg_output, obj_output)
 *
 * NMS 使用标准贪心算法，IoU 阈值可配。
 */

#include "postprocessor.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>

namespace rk3588 {
namespace engine {

// ============================================================================
// PIMPL 实现结构
// ============================================================================

struct Postprocessor::Impl {
  PostprocessConfig config;

  // YOLO 锚框 (YOLOv5s 默认)
  // 三层检测头对应的 anchor 尺寸
  static constexpr int kNumAnchors = 3;
  float anchors[3][3][2] = {
      {{10, 13}, {16, 30}, {33, 23}},       // P3/8  (小目标)
      {{30, 61}, {62, 45}, {59, 119}},       // P4/16 (中目标)
      {{116, 90}, {156, 198}, {373, 326}}    // P5/32 (大目标)
  };

  // 步长
  static constexpr int kStrides[3] = {8, 16, 32};
};

// ============================================================================
// 构造 / 析构
// ============================================================================

Postprocessor::Postprocessor(const PostprocessConfig& config)
    : impl_(std::make_unique<Impl>()) {
  impl_->config = config;
}

Postprocessor::~Postprocessor() = default;

// ============================================================================
// COCO 80 类默认名称
// ============================================================================

std::vector<std::string> Postprocessor::DefaultCocoNames() {
  return {
      "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train",
      "truck", "boat", "traffic light", "fire hydrant", "stop sign",
      "parking meter", "bench", "bird", "cat", "dog", "horse", "sheep",
      "cow", "elephant", "bear", "zebra", "giraffe", "backpack", "umbrella",
      "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard",
      "sports ball", "kite", "baseball bat", "baseball glove", "skateboard",
      "surfboard", "tennis racket", "bottle", "wine glass", "cup", "fork",
      "knife", "spoon", "bowl", "banana", "apple", "sandwich", "orange",
      "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair",
      "couch", "potted plant", "bed", "dining table", "toilet", "tv",
      "laptop", "mouse", "remote", "keyboard", "cell phone", "microwave",
      "oven", "toaster", "sink", "refrigerator", "book", "clock", "vase",
      "scissors", "teddy bear", "hair drier", "toothbrush"
  };
}

// ============================================================================
// 后处理入口
// ============================================================================

std::vector<Detection> Postprocessor::Process(const float* const* outputs,
                                              const uint32_t* output_sizes,
                                              uint32_t num_outputs,
                                              YoloFormat format) {
  switch (format) {
    case YoloFormat::YOLOV5:
      return ParseYoloV5(outputs, output_sizes, num_outputs);
    case YoloFormat::YOLOV8:
      return ParseYoloV8(outputs, output_sizes, num_outputs);
    case YoloFormat::YOLOX:
      return ParseYoloX(outputs, output_sizes, num_outputs);
    default:
      return {};
  }
}

// ============================================================================
// YOLOv5 解析
// ============================================================================

std::vector<Detection> Postprocessor::ParseYoloV5(const float* const* outputs,
                                                  const uint32_t* output_sizes,
                                                  uint32_t num_outputs) {
  std::vector<Detection> detections;
  const auto& cfg = impl_->config;
  const int num_classes = cfg.num_classes;
  const int box_attr_count = 5 + num_classes;  // x,y,w,h,obj_conf + classes

  for (uint32_t layer = 0; layer < num_outputs && layer < 3; ++layer) {
    const float* output = outputs[layer];
    if (!output) continue;

    int stride = Impl::kStrides[layer];
    int grid_h = cfg.input_height / stride;
    int grid_w = cfg.input_width / stride;
    int num_anchors = Impl::kNumAnchors;

    // 遍历每个网格单元 × 锚框
    for (int gy = 0; gy < grid_h; ++gy) {
      for (int gx = 0; gx < grid_w; ++gx) {
        for (int a = 0; a < num_anchors; ++a) {
          int offset = (a * grid_h * grid_w + gy * grid_w + gx) * box_attr_count;
          if (static_cast<uint32_t>(offset + box_attr_count) > output_sizes[layer] / sizeof(float)) {
            continue;
          }

          // 目标置信度 (sigmoid 激活)
          float obj_conf = 1.0f / (1.0f + std::exp(-output[offset + 4]));

          // 类别置信度 (sigmoid 激活取 max)
          float max_cls_conf = 0.0f;
          int best_class = -1;
          for (int c = 0; c < num_classes; ++c) {
            float cls_conf = 1.0f / (1.0f + std::exp(-output[offset + 5 + c]));
            if (cls_conf > max_cls_conf) {
              max_cls_conf = cls_conf;
              best_class = c;
            }
          }

          float confidence = obj_conf * max_cls_conf;
          if (confidence < cfg.conf_threshold) continue;

          // 坐标解码 (cx,cy,w,h → x1,y1,x2,y2 归一化)
          float cx = (1.0f / (1.0f + std::exp(-output[offset + 0])) * 2.0f - 0.5f + gx) * stride;
          float cy = (1.0f / (1.0f + std::exp(-output[offset + 1])) * 2.0f - 0.5f + gy) * stride;
          float w = std::pow(1.0f / (1.0f + std::exp(-output[offset + 2])) * 2.0f, 2) *
                    Impl::kStrides[layer] * impl_->anchors[layer][a][0];
          float h = std::pow(1.0f / (1.0f + std::exp(-output[offset + 3])) * 2.0f, 2) *
                    Impl::kStrides[layer] * impl_->anchors[layer][a][1];

          Detection det;
          det.class_id = best_class;
          det.confidence = confidence;
          det.x1 = (cx - w / 2.0f) / cfg.input_width;
          det.y1 = (cy - h / 2.0f) / cfg.input_height;
          det.x2 = (cx + w / 2.0f) / cfg.input_width;
          det.y2 = (cy + h / 2.0f) / cfg.input_height;

          // 裁剪到 [0, 1]
          det.x1 = std::max(0.0f, std::min(det.x1, 1.0f));
          det.y1 = std::max(0.0f, std::min(det.y1, 1.0f));
          det.x2 = std::max(0.0f, std::min(det.x2, 1.0f));
          det.y2 = std::max(0.0f, std::min(det.y2, 1.0f));

          // 设置类别名称
          if (best_class >= 0 &&
              static_cast<size_t>(best_class) < cfg.class_names.size()) {
            det.class_name = cfg.class_names[best_class];
          }

          detections.push_back(det);
        }
      }
    }
  }

  return ApplyNMS(detections);
}

// ============================================================================
// YOLOv8 解析 (anchor-free)
// ============================================================================

std::vector<Detection> Postprocessor::ParseYoloV8(const float* const* outputs,
                                                  const uint32_t* output_sizes,
                                                  uint32_t num_outputs) {
  std::vector<Detection> detections;
  const auto& cfg = impl_->config;
  const int num_classes = cfg.num_classes;
  const int reg_max = 16;  // DFL 通道数 (YOLOv8 默认)

  for (uint32_t layer = 0; layer < num_outputs && layer < 3; ++layer) {
    const float* output = outputs[layer];
    if (!output) continue;

    int stride = Impl::kStrides[layer];
    int grid_h = cfg.input_height / stride;
    int grid_w = cfg.input_width / stride;

    // YOLOv8 输出: [batch, reg_max*4 + num_classes, grid_h, grid_w]
    // 但在 NHWC 排布下 reshape 为 [grid_h, grid_w, reg_max*4 + num_classes]
    int channel_count = reg_max * 4 + num_classes;

    for (int gy = 0; gy < grid_h; ++gy) {
      for (int gx = 0; gx < grid_w; ++gx) {
        int base = (gy * grid_w + gx) * channel_count;
        if (static_cast<uint32_t>(base + channel_count) > output_sizes[layer] / sizeof(float)) {
          continue;
        }

        // 类别置信度 (取 max)
        float max_cls_conf = 0.0f;
        int best_class = -1;
        for (int c = 0; c < num_classes; ++c) {
          float cls_conf = 1.0f / (1.0f + std::exp(-output[base + reg_max * 4 + c]));
          if (cls_conf > max_cls_conf) {
            max_cls_conf = cls_conf;
            best_class = c;
          }
        }

        if (max_cls_conf < cfg.conf_threshold) continue;

        // DFL 解码边界框 (简化: 使用 softmax 加权)
        // 实际实现中需要完整的 Distribution Focal Loss 解码
        // cx,cy computed but unused in current YOLOv8 pipeline

        // 简化: 取 reg_max 通道的加权平均作为偏移
        float offset_l = 0.0f, offset_t = 0.0f, offset_r = 0.0f, offset_b = 0.0f;
        for (int j = 0; j < reg_max; ++j) {
          float weight_l = std::exp(output[base + j]);
          float weight_t = std::exp(output[base + reg_max + j]);
          float weight_r = std::exp(output[base + 2 * reg_max + j]);
          float weight_b = std::exp(output[base + 3 * reg_max + j]);
          offset_l += weight_l * j;
          offset_t += weight_t * j;
          offset_r += weight_r * j;
          offset_b += weight_b * j;
        }
        float sum_l = 0.0f, sum_t = 0.0f, sum_r = 0.0f, sum_b = 0.0f;
        for (int j = 0; j < reg_max; ++j) {
          sum_l += std::exp(output[base + j]);
          sum_t += std::exp(output[base + reg_max + j]);
          sum_r += std::exp(output[base + 2 * reg_max + j]);
          sum_b += std::exp(output[base + 3 * reg_max + j]);
        }
        offset_l = (sum_l > 0) ? offset_l / sum_l : 0.0f;
        offset_t = (sum_t > 0) ? offset_t / sum_t : 0.0f;
        offset_r = (sum_r > 0) ? offset_r / sum_r : 0.0f;
        offset_b = (sum_b > 0) ? offset_b / sum_b : 0.0f;

        float x1 = (gx - offset_l) * stride / cfg.input_width;
        float y1 = (gy - offset_t) * stride / cfg.input_height;
        float x2 = (gx + offset_r) * stride / cfg.input_width;
        float y2 = (gy + offset_b) * stride / cfg.input_height;

        Detection det;
        det.class_id = best_class;
        det.confidence = max_cls_conf;
        det.x1 = std::max(0.0f, std::min(x1, 1.0f));
        det.y1 = std::max(0.0f, std::min(y1, 1.0f));
        det.x2 = std::max(0.0f, std::min(x2, 1.0f));
        det.y2 = std::max(0.0f, std::min(y2, 1.0f));

        if (best_class >= 0 &&
            static_cast<size_t>(best_class) < cfg.class_names.size()) {
          det.class_name = cfg.class_names[best_class];
        }

        detections.push_back(det);
      }
    }
  }

  return ApplyNMS(detections);
}

// ============================================================================
// YOLOX 解析 (decoupled head)
// ============================================================================

std::vector<Detection> Postprocessor::ParseYoloX(const float* const* outputs,
                                                 const uint32_t* output_sizes,
                                                 uint32_t num_outputs) {
  // YOLOX 使用解耦头: 三个输出 (cls_output, reg_output, obj_output)
  // 此处提供框架代码，完整实现需结合实际模型结构
  std::vector<Detection> detections;
  // TODO: 实现 YOLOX decoupled head 解析
  return detections;
}

// ============================================================================
// NMS 非极大值抑制
// ============================================================================

std::vector<Detection> Postprocessor::ApplyNMS(std::vector<Detection>& detections) {
  if (detections.empty()) return {};

  const auto& cfg = impl_->config;

  // 按置信度降序排序
  std::sort(detections.begin(), detections.end(),
            [](const Detection& a, const Detection& b) {
              return a.confidence > b.confidence;
            });

  std::vector<Detection> result;
  std::vector<bool> suppressed(detections.size(), false);

  for (size_t i = 0; i < detections.size(); ++i) {
    if (suppressed[i]) continue;

    result.push_back(detections[i]);

    for (size_t j = i + 1; j < detections.size(); ++j) {
      if (suppressed[j]) continue;

      // 类别无关 NMS 或同类别 NMS
      if (!cfg.use_class_agnostic_nms &&
          detections[i].class_id != detections[j].class_id) {
        continue;
      }

      float iou = ComputeIoU(detections[i], detections[j]);
      if (iou > cfg.nms_threshold) {
        suppressed[j] = true;
      }
    }
  }

  return result;
}

// ============================================================================
// IoU 计算
// ============================================================================

float Postprocessor::ComputeIoU(const Detection& a, const Detection& b) {
  float inter_x1 = std::max(a.x1, b.x1);
  float inter_y1 = std::max(a.y1, b.y1);
  float inter_x2 = std::min(a.x2, b.x2);
  float inter_y2 = std::min(a.y2, b.y2);

  if (inter_x2 <= inter_x1 || inter_y2 <= inter_y1) {
    return 0.0f;
  }

  float inter_area = (inter_x2 - inter_x1) * (inter_y2 - inter_y1);
  float area_a = (a.x2 - a.x1) * (a.y2 - a.y1);
  float area_b = (b.x2 - b.x1) * (b.y2 - b.y1);
  float union_area = area_a + area_b - inter_area;

  return (union_area > 0.0f) ? (inter_area / union_area) : 0.0f;
}

// ============================================================================
// 配置更新
// ============================================================================

void Postprocessor::UpdateConfig(const PostprocessConfig& config) {
  impl_->config = config;
}

}  // namespace engine
}  // namespace rk3588
