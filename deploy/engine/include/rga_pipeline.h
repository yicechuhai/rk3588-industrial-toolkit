#pragma once

/**
 * @file rga_pipeline.h
 * @brief RGA 硬件加速流水线 — V4L2 采集 → RGA 格式转换 → NPU 推理输入
 *
 * 全程使用 DMA-BUF 零拷贝：
 *   1. V4L2 摄像头采集 NV12 帧，mmap + EXPBUF → DMA-BUF fd
 *   2. RGA im2d API (importbuffer_fd/wrapbuffer_handle/improcess) 转换 NV12 → RGB
 *   3. 输出 DMA-BUF fd 直接送入 RKNN NPU 推理
 *
 * 使用 librga.so 的 im2d 新 API (librga >= 2.0)，替代废弃的 c_RkRgaBlit。
 *
 * @author RK3588 Industrial Toolkit
 * @version 1.0.0
 */

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

struct v4l2_format;
struct v4l2_buffer;

namespace rk3588 {
namespace engine {

/** @brief V4L2 缓冲区状态 */
enum class BufferState {
  UNUSED,
  QUEUED,
  DEQUEUED,
};

/** @brief V4L2 缓冲区帧信息 */
struct FrameBuffer {
  uint32_t index = 0;
  int dma_fd = -1;
  void* start = nullptr;
  uint32_t length = 0;
  BufferState state = BufferState::UNUSED;
  uint32_t sequence = 0;
  uint64_t timestamp_ns = 0;
  uint32_t bytesused = 0;
};

/** @brief V4L2 摄像头配置 */
struct CameraConfig {
  std::string device = "/dev/video0";
  uint32_t width = 1920;
  uint32_t height = 1080;
  uint32_t fps = 30;
  uint32_t pixelformat = 0;      // V4L2_PIX_FMT_NV12 (避免依赖 linux/videodev2.h)
  uint32_t buffer_count = 4;
  bool use_dmabuf = true;
};

/** @brief RGA 转换配置 */
struct RgaConvertConfig {
  uint32_t src_width = 1920;
  uint32_t src_height = 1080;
  uint32_t dst_width = 640;
  uint32_t dst_height = 640;
  uint32_t src_format = 0;       // V4L2_PIX_FMT_NV12
  uint32_t dst_format = 0;       // V4L2_PIX_FMT_RGB32
  bool letterbox = true;
};

/** @brief RGA 流水线输出帧 (DMA-BUF 零拷贝) */
struct PipelineFrame {
  int dma_fd = -1;
  void* virt_addr = nullptr;
  uint32_t size = 0;
  uint32_t width = 0;
  uint32_t height = 0;
  uint32_t sequence = 0;
  uint64_t timestamp_ns = 0;
};

/**
 * @class RgaPipeline
 * @brief V4L2 采集 + RGA 硬件加速预处理流水线
 *
 * 将摄像头采集的 NV12 帧通过 RGA im2d API 转换为 NPU 接受的 RGB 输入，
 * 全程通过 DMA-BUF 共享内存，无 CPU memcpy 参与。
 *
 * 使用示例:
 * @code
 *   CameraConfig cam_cfg;
 *   cam_cfg.device = "/dev/video0";
 *   cam_cfg.width = 1920;
 *   cam_cfg.height = 1080;
 *
 *   RgaConvertConfig rga_cfg;
 *   rga_cfg.dst_width = 640;
 *   rga_cfg.dst_height = 640;
 *
 *   RgaPipeline pipeline(cam_cfg, rga_cfg);
 *   pipeline.Init();
 *
 *   auto frame = pipeline.CaptureAndConvert();
 *   // frame.dma_fd 可直接用于 rknn_set_io_mem 实现零拷贝
 *   pipeline.ReleaseFrame(frame);
 *   pipeline.Stop();
 * @endcode
 */
class RgaPipeline {
 public:
  RgaPipeline(const CameraConfig& cam_cfg, const RgaConvertConfig& rga_cfg);
  ~RgaPipeline();

  RgaPipeline(const RgaPipeline&) = delete;
  RgaPipeline& operator=(const RgaPipeline&) = delete;
  RgaPipeline(RgaPipeline&&) = delete;
  RgaPipeline& operator=(RgaPipeline&&) = delete;

  bool Init();
  PipelineFrame CaptureAndConvert();
  void ReleaseFrame(PipelineFrame& frame);
  void Stop();
  bool IsReady() const;
  double GetFps() const;

 private:
  bool OpenDevice();
  bool SetFormat();
  bool RequestBuffers();
  bool StartCapture();
  void RequeueBuffer(uint32_t buf_idx);
  bool AllocOutputDmaBuf();
  void FreeOutputDmaBuf();
  void CalcLetterbox(int src_w, int src_h, int dst_w, int dst_h,
                     int& crop_x, int& crop_y, int& crop_w, int& crop_h) const;

  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace engine
}  // namespace rk3588
