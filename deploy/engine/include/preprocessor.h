#pragma once

/**
 * @file preprocessor.h
 * @brief 图像预处理模块 — 基于 RGA 硬件加速
 *
 * 利用 RK3588 内置 RGA (Raster Graphic Accelerator) 进行
 * 图像缩放、裁剪、颜色空间转换和归一化。
 * 输出为物理连续内存 (DMA-BUF)，可直接送入 NPU。
 *
 * @author RK3588 Industrial Toolkit
 * @version 1.0.0
 */

#include <cstdint>
#include <string>
#include <vector>

namespace rk3588 {
namespace engine {

/** @brief 像素格式枚举 */
enum class PixelFormat {
  NV12,     ///< YUV 4:2:0 半平面 (常见摄像头输出)
  NV21,     ///< YUV 4:2:0 半平面 (Android 默认)
  RGB888,   ///< RGB 24-bit
  BGR888,   ///< BGR 24-bit (OpenCV 默认)
  RGBA8888, ///< RGBA 32-bit
  GRAY8,    ///< 灰度 8-bit
};

/** @brief RGA 操作模式 */
enum class RgaMode {
  RESIZE,              ///< 纯缩放
  RESIZE_CROP,         ///< 缩放 + 居中裁剪 (letterbox)
  RESIZE_COLOR_CONVERT, ///< 缩放 + 颜色空间转换
  FULL,                ///< 缩放 + 颜色转换 + 归一化
};

/** @brief 预处理配置 */
struct PreprocessConfig {
  int target_width = 640;              ///< 目标宽度
  int target_height = 640;             ///< 目标高度
  std::vector<float> mean = {0, 0, 0}; ///< 归一化均值 (BGR 顺序)
  std::vector<float> std = {255, 255, 255}; ///< 归一化标准差 (BGR 顺序)
  bool letterbox = true;               ///< 是否保持宽高比 (letterbox)
  bool normalize = true;               ///< 是否执行归一化
  bool use_rga = true;                 ///< 是否使用 RGA 硬件加速
};

/** @brief 预处理后的张量数据 */
struct PreprocessedTensor {
  uint8_t* data = nullptr;      ///< 张量数据指针 (物理连续内存)
  int fd = -1;                  ///< DMA-BUF 文件描述符
  uint32_t size = 0;            ///< 数据字节数
  uint32_t width = 0;           ///< 实际宽度
  uint32_t height = 0;          ///< 实际高度
  PixelFormat format;           ///< 像素格式
  bool owns_memory = false;     ///< 是否需要释放内存
};

/**
 * @class Preprocessor
 * @brief RGA 硬件加速图像预处理
 *
 * 提供零拷贝预处理管线:
 * 输入帧 (DMA-BUF) → RGA 缩放/颜色转换 → 物理连续输出 → NPU 输入
 *
 * 使用示例:
 * @code
 *   Preprocessor pre(config);
 *   auto tensor = pre.Process(frame_data, 1920, 1080, PixelFormat::NV12);
 *   // tensor.fd 可直接传给 rknn_set_io_mem() 实现零拷贝
 * @endcode
 */
class Preprocessor {
 public:
  /**
   * @brief 使用预处理配置构造
   * @param config 预处理参数
   */
  explicit Preprocessor(const PreprocessConfig& config);

  ~Preprocessor();

  // 禁止拷贝
  Preprocessor(const Preprocessor&) = delete;
  Preprocessor& operator=(const Preprocessor&) = delete;

  /**
   * @brief 执行图像预处理
   * @param src_data 源图像数据
   * @param src_width 源宽度
   * @param src_height 源高度
   * @param src_format 源像素格式
   * @return 预处理后的张量（含 DMA-BUF fd）
   */
  PreprocessedTensor Process(const uint8_t* src_data, int src_width, int src_height,
                             PixelFormat src_format);

  /**
   * @brief 释放预处理结果内存
   * @param tensor 待释放的张量
   */
  void ReleaseTensor(PreprocessedTensor& tensor);

  /**
   * @brief 获取目标输入尺寸
   * @return {width, height}
   */
  std::pair<int, int> GetTargetSize() const;

  /**
   * @brief 更新预处理配置
   * @param config 新配置
   */
  void UpdateConfig(const PreprocessConfig& config);

 private:
  /** @brief 通过 RGA 执行缩放和颜色转换 */
  bool RgaResize(const uint8_t* src, int src_w, int src_h, PixelFormat src_fmt,
                 PreprocessedTensor& dst);

  /** @brief CPU 回退路径 (当 RGA 不可用时) */
  bool CpuPreprocess(const uint8_t* src, int src_w, int src_h, PixelFormat src_fmt,
                     PreprocessedTensor& dst);

  /** @brief 分配 DMA-BUF 物理连续内存 */
  bool AllocateDmaBuf(PreprocessedTensor& tensor, uint32_t size);

  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace engine
}  // namespace rk3588
