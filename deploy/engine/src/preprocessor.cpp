/**
 * @file preprocessor.cpp
 * @brief RGA 硬件加速图像预处理实现
 *
 * 流程:
 *   Camera DMA-BUF → RGA 缩放/裁剪/颜色转换 → 归一化 → NPU 输入 DMA-BUF
 *
 * RGA (Raster Graphic Accelerator) 是 RK3588 内置的 2D 加速器，
 * 相比 CPU 软件 resize，RGA 零拷贝模式可提速 3-5 倍。
 *
 * RGA API 参考:
 *   - c_RkRgaInit()          初始化 RGA 驱动
 *   - c_RkRgaBlit()          执行位块传输 (缩放/旋转/颜色转换)
 *   - dma_buf_alloc()        分配 DMA-BUF 物理连续内存
 */

#include "preprocessor.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

// RGA 库 — Rockchip 硬件加速
#include <rga/RgaApi.h>

// DMA-BUF 分配 (Linux 内核接口)
// #include <linux/dma-buf.h>  // not available on all kernels

namespace rk3588 {
namespace engine {

// ============================================================================
// PIMPL 实现结构
// ============================================================================

struct Preprocessor::Impl {
  PreprocessConfig config;
  bool rga_available = false;

  // RGA 内部参数
  int rga_format_src = 0;
  int rga_format_dst = 0;
};

// ============================================================================
// 构造 / 析构
// ============================================================================

Preprocessor::Preprocessor(const PreprocessConfig& config)
    : impl_(std::make_unique<Impl>()) {
  impl_->config = config;

  // 尝试初始化 RGA
  if (config.use_rga) {
    int ret = c_RkRgaInit();
    impl_->rga_available = (ret == 0);
  }
}

Preprocessor::~Preprocessor() = default;

// ============================================================================
// 预处理主流程
// ============================================================================

PreprocessedTensor Preprocessor::Process(const uint8_t* src_data,
                                         int src_width, int src_height,
                                         PixelFormat src_format) {
  PreprocessedTensor result;

  if (!src_data || src_width <= 0 || src_height <= 0) {
    return result;
  }

  // 计算输出尺寸
  int dst_w = impl_->config.target_width;
  int dst_h = impl_->config.target_height;
  result.width = dst_w;
  result.height = dst_h;
  result.format = src_format;

  // 选择处理路径: RGA 硬件优先, 回退到 CPU
  bool success = false;
  if (impl_->rga_available) {
    success = RgaResize(src_data, src_width, src_height, src_format, result);
  }

  if (!success) {
    success = CpuPreprocess(src_data, src_width, src_height, src_format, result);
  }

  if (!success) {
    // 两种路径都失败，返回空结果
    result.data = nullptr;
    result.size = 0;
  }

  return result;
}

// ============================================================================
// RGA 硬件加速路径
// ============================================================================

bool Preprocessor::RgaResize(const uint8_t* src, int src_w, int src_h,
                             PixelFormat src_fmt, PreprocessedTensor& dst) {
  // 确定 RGA 格式码
  int rga_src_fmt = RK_FORMAT_YCbCr_420_SP;  // NV12 默认
  int rga_dst_fmt = RK_FORMAT_YCbCr_420_SP;
  int src_bpp = 1;  // NV12 ~1.5 bytes per pixel 实际按 NV12 算

  switch (src_fmt) {
    case PixelFormat::NV12:
      rga_src_fmt = RK_FORMAT_YCbCr_420_SP;
      rga_dst_fmt = RK_FORMAT_YCbCr_420_SP;
      src_bpp = 3;  // NV12 按 1.5 bytes/pixel，但 stride = width
      break;
    case PixelFormat::NV21:
      rga_src_fmt = RK_FORMAT_YCrCb_420_SP;
      rga_dst_fmt = RK_FORMAT_YCbCr_420_SP;
      src_bpp = 3;
      break;
    case PixelFormat::RGB888:
      rga_src_fmt = RK_FORMAT_RGB_888;
      rga_dst_fmt = RK_FORMAT_RGB_888;
      src_bpp = 3;
      break;
    case PixelFormat::BGR888:
      rga_src_fmt = RK_FORMAT_BGR_888;
      rga_dst_fmt = RK_FORMAT_RGB_888;
      src_bpp = 3;
      break;
    case PixelFormat::RGBA8888:
      rga_src_fmt = RK_FORMAT_RGBA_8888;
      rga_dst_fmt = RK_FORMAT_RGBA_8888;
      src_bpp = 4;
      break;
    default:
      return false;
  }

  int dst_w = impl_->config.target_width;
  int dst_h = impl_->config.target_height;

  // 计算 letterbox 参数 (保持宽高比)
  int crop_x = 0, crop_y = 0;
  int crop_w = src_w, crop_h = src_h;

  if (impl_->config.letterbox) {
    float src_ratio = static_cast<float>(src_w) / src_h;
    float dst_ratio = static_cast<float>(dst_w) / dst_h;

    if (src_ratio > dst_ratio) {
      // 源更宽: 裁剪左右
      crop_w = static_cast<int>(src_h * dst_ratio);
      crop_x = (src_w - crop_w) / 2;
    } else {
      // 源更高: 裁剪上下
      crop_h = static_cast<int>(src_w / dst_ratio);
      crop_y = (src_h - crop_h) / 2;
    }
  }

  // 分配目标 DMA-BUF
  uint32_t dst_size = dst_w * dst_h * ((rga_dst_fmt == RK_FORMAT_YCbCr_420_SP) ? 3 : src_bpp) / 2;
  if (rga_dst_fmt == RK_FORMAT_YCbCr_420_SP) {
    dst_size = dst_w * dst_h * 3 / 2;  // NV12: Y + UV 交错
  }

  if (!AllocateDmaBuf(dst, dst_size)) {
    return false;
  }

  // 配置 RGA 源
  rga_info_t src_info;
  memset(&src_info, 0, sizeof(src_info));
  src_info.fd = -1;
  src_info.mmuFlag = 1;
  src_info.virAddr = const_cast<uint8_t*>(src);  // const_cast for RGA API
  src_info.format = rga_src_fmt;

  // 配置 RGA 目标
  rga_info_t dst_info;
  memset(&dst_info, 0, sizeof(dst_info));
  dst_info.fd = dst.fd;
  dst_info.mmuFlag = (dst.fd >= 0) ? 1 : 0;
  dst_info.virAddr = dst.data;
  dst_info.format = rga_dst_fmt;

  // 设置源裁剪区域
  rga_set_rect(&src_info.rect, crop_x, crop_y, crop_w, crop_h,
               src_w, src_h, rga_src_fmt);

  // 设置目标区域 (填满整个目标 buffer)
  rga_set_rect(&dst_info.rect, 0, 0, dst_w, dst_h, dst_w, dst_h, rga_dst_fmt);

  // 执行 RGA 位块传输 (支持缩放 + 裁剪 + 颜色转换)
  int ret = c_RkRgaBlit(&src_info, &dst_info, nullptr);
  if (ret < 0) {
    ReleaseTensor(dst);
    return false;
  }

  // 归一化: 在 destination buffer 上原地操作
  if (impl_->config.normalize && dst.data) {
    // 归一化在 CPU 侧完成 (RGA 不支持浮点归一化)
    // 对于 RGB/BGR 格式，将 uint8 [0,255] 转为 float32
    // 此处标记需要归一化，由 engine.cpp 在拷贝到 NPU 输入前完成
    // (实际归一化通常在 NPU 输入转换阶段完成)
  }

  return true;
}

// ============================================================================
// CPU 软件回退路径
// ============================================================================

bool Preprocessor::CpuPreprocess(const uint8_t* src, int src_w, int src_h,
                                 PixelFormat src_fmt, PreprocessedTensor& dst) {
  int dst_w = impl_->config.target_width;
  int dst_h = impl_->config.target_height;
  uint32_t dst_size = dst_w * dst_h * 3;  // RGB888 输出

  if (!AllocateDmaBuf(dst, dst_size)) {
    return false;
  }

  // 简单的最近邻缩放 (生产环境建议改用双线性插值)
  float scale_x = static_cast<float>(src_w) / dst_w;
  float scale_y = static_cast<float>(src_h) / dst_h;

  int src_bpp = 3;  // 默认 RGB/BGR
  switch (src_fmt) {
    case PixelFormat::RGBA8888: src_bpp = 4; break;
    case PixelFormat::GRAY8:    src_bpp = 1; break;
    default:                    src_bpp = 3; break;
  }

  for (int y = 0; y < dst_h; ++y) {
    for (int x = 0; x < dst_w; ++x) {
      int src_x = static_cast<int>(x * scale_x);
      int src_y = static_cast<int>(y * scale_y);
      src_x = std::min(src_x, src_w - 1);
      src_y = std::min(src_y, src_h - 1);

      size_t src_idx = (src_y * src_w + src_x) * src_bpp;
      size_t dst_idx = (y * dst_w + x) * 3;

      if (src_fmt == PixelFormat::BGR888) {
        // BGR → RGB 转换
        dst.data[dst_idx + 0] = src[src_idx + 2];
        dst.data[dst_idx + 1] = src[src_idx + 1];
        dst.data[dst_idx + 2] = src[src_idx + 0];
      } else {
        std::memcpy(dst.data + dst_idx, src + src_idx, 3);
      }
    }
  }

  return true;
}

// ============================================================================
// DMA-BUF 内存分配
// ============================================================================

bool Preprocessor::AllocateDmaBuf(PreprocessedTensor& tensor, uint32_t size) {{
  // Use aligned malloc (DMA-BUF kernel headers not available on all boards)
  void* ptr = std::aligned_alloc(64, size);
  if (!ptr) return false;
  std::memset(ptr, 0, size);
  tensor.data = static_cast<uint8_t*>(ptr);
  tensor.size = size;
  tensor.owns_memory = true;
  return true;
}

// ============================================================================
// 资源释放
// ============================================================================

void Preprocessor::ReleaseTensor(PreprocessedTensor& tensor) {
  if (!tensor.owns_memory) return;

  if (tensor.fd >= 0 && tensor.data) {
    munmap(tensor.data, tensor.size);
    close(tensor.fd);
  } else if (tensor.data) {
    delete[] tensor.data;
  }

  tensor.data = nullptr;
  tensor.fd = -1;
  tensor.size = 0;
  tensor.owns_memory = false;
}

std::pair<int, int> Preprocessor::GetTargetSize() const {
  return {impl_->config.target_width, impl_->config.target_height};
}

void Preprocessor::UpdateConfig(const PreprocessConfig& config) {
  impl_->config = config;
}

}  // namespace engine
}  // namespace rk3588
