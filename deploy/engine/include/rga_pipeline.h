#pragma once

/**
 * @file rga_pipeline.h
 * @brief RGA 硬件加速流水线 — V4L2 采集 → RGA 格式转换 → NPU 推理输入
 *
 * 全程使用 DMA-BUF 零拷贝：
 *   1. V4L2 摄像头采集 NV12 帧到 DMA-BUF
 *   2. RGA im2d API (imimport/improcess/imexport) 转换 NV12 → RGB
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

#include <linux/videodev2.h>

namespace rk3588 {
namespace engine {

/** @brief V4L2 缓冲区状态 */
enum class BufferState {
  UNUSED,       ///< 未使用
  QUEUED,       ///< 已入队等待采集
  DEQUEUED,     ///< 已出队待处理
};

/** @brief V4L2 缓冲区帧信息 */
struct FrameBuffer {
  uint32_t index = 0;         ///< 缓冲区索引
  int dma_fd = -1;            ///< DMA-BUF 文件描述符
  void* start = nullptr;      ///< mmap 用户空间地址
  uint32_t length = 0;        ///< 缓冲区长度 (bytes)
  BufferState state = BufferState::UNUSED;

  // V4L2 帧元数据
  uint32_t sequence = 0;      ///< 帧序号
  uint64_t timestamp_ns = 0;  ///< 采集时间戳 (ns)
  uint32_t bytesused = 0;     ///< 实际数据字节数
};

/** @brief V4L2 摄像头配置 */
struct CameraConfig {
  std::string device = "/dev/video0";  ///< 摄像头设备节点
  uint32_t width = 1920;               ///< 采集宽度
  uint32_t height = 1080;              ///< 采集高度
  uint32_t fps = 30;                   ///< 采集帧率
  uint32_t pixelformat = V4L2_PIX_FMT_NV12;  ///< 像素格式 (默认 NV12)
  uint32_t buffer_count = 4;           ///< V4L2 缓冲区数量
  bool use_dmabuf = true;              ///< 使用 DMA-BUF 而非 mmap
};

/** @brief RGA 转换配置 */
struct RgaConvertConfig {
  uint32_t src_width = 1920;           ///< 源宽度
  uint32_t src_height = 1080;          ///< 源高度
  uint32_t dst_width = 640;            ///< 目标宽度 (模型输入)
  uint32_t dst_height = 640;           ///< 目标高度 (模型输入)
  uint32_t src_format = V4L2_PIX_FMT_NV12;    ///< 源格式 (默认 NV12)
  uint32_t dst_format = V4L2_PIX_FMT_RGB32;   ///< 目标格式 (默认 RGB888)
  bool letterbox = true;               ///< 保持宽高比填充
};

/** @brief RGA 流水线输出帧 (DMA-BUF 零拷贝) */
struct PipelineFrame {
  int dma_fd = -1;              ///< 输出 DMA-BUF fd
  void* virt_addr = nullptr;    ///< 用户空间映射地址
  uint32_t size = 0;            ///< 数据大小 (bytes)
  uint32_t width = 0;           ///< 帧宽度
  uint32_t height = 0;          ///< 帧高度
  uint32_t sequence = 0;        ///< 源帧序号
  uint64_t timestamp_ns = 0;    ///< 源采集时间戳
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
 *   // frame.dma_fd 可直接用于 rknn_set_io_mem
 *   pipeline.ReleaseFrame(frame);
 *
 *   pipeline.Stop();
 * @endcode
 */
class RgaPipeline {
 public:
  /**
   * @brief 构造 RGA 流水线
   * @param cam_cfg 摄像头采集配置
   * @param rga_cfg RGA 格式转换配置
   */
  RgaPipeline(const CameraConfig& cam_cfg, const RgaConvertConfig& rga_cfg);

  ~RgaPipeline();

  // 禁止拷贝
  RgaPipeline(const RgaPipeline&) = delete;
  RgaPipeline& operator=(const RgaPipeline&) = delete;
  RgaPipeline(RgaPipeline&&) = delete;
  RgaPipeline& operator=(RgaPipeline&&) = delete;

  /**
   * @brief 初始化流水线（打开摄像头、配置 V4L2、分配 RGA 目标 DMA-BUF）
   * @return 成功返回 true
   */
  bool Init();

  /**
   * @brief 执行一帧采集 + RGA 转换
   *
   * 流程:
   *   V4L2 DQBUF → imimport(DMA-BUF fd) → improcess(NV12→RGB) →
   *   imexport(DMA-BUF) → PipelineFrame
   *
   * @return 转换后的 PipelineFrame（含 DMA-BUF fd）
   */
  PipelineFrame CaptureAndConvert();

  /**
   * @brief 释放流水线输出帧（归还 DMA-BUF）
   * @param frame 待释放的帧
   */
  void ReleaseFrame(PipelineFrame& frame);

  /**
   * @brief 停止采集，关闭设备
   */
  void Stop();

  /**
   * @brief 检查流水线是否已初始化
   * @return 已就绪返回 true
   */
  bool IsReady() const;

  /**
   * @brief 获取当前帧率统计
   * @return 采集帧率 (FPS)
   */
  double GetFps() const;

 private:
  /** @brief 打开 V4L2 设备 */
  bool OpenDevice();

  /** @brief 配置 V4L2 格式 */
  bool SetFormat();

  /** @brief 请求 V4L2 缓冲区 */
  bool RequestBuffers();

  /** @brief 队列所有缓冲区，开始采集 */
  bool StartCapture();

  /** @brief 分配 RGA 输出 DMA-BUF 内存 */
  bool AllocOutputDmaBuf();

  /** @brief 释放 RGA 输出 DMA-BUF 内存 */
  void FreeOutputDmaBuf();

  /** @brief 计算 letterbox 裁剪参数 */
  void CalcLetterbox(int src_w, int src_h, int dst_w, int dst_h,
                     int& crop_x, int& crop_y, int& crop_w, int& crop_h) const;

  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace engine
}  // namespace rk3588
