/**
 * @file rga_pipeline.cpp
 * @brief RGA 硬件加速流水线实现 — V4L2 采集 → RGA 格式转换 → NPU 推理输入
 *
 * 流水线:
 *   /dev/video0 (V4L2, NV12, DMA-BUF)
 *       ↓ V4L2 DQBUF → DMA-BUF fd
 *    imimport(fd) → 包装为 rga_buffer_t
 *       ↓
 *    improcess(NV12 → RGB, letterbox 缩放)
 *       ↓
 *    imexport(DMA-BUF) → PipelineFrame.dma_fd → NPU 输入
 *
 * 全程零拷贝: RGA 直接在 DMA-BUF 上操作，不经过 CPU memcpy。
 *
 * im2d API 文档参考:
 *   - im2d.hpp: imimport, improcess, imexport, imfill
 *   - librga.so >= 2.0, RK3588 内置 RGA 3.0
 *
 * @author RK3588 Industrial Toolkit
 * @version 1.0.0
 */

#include "rga_pipeline.h"

#include <algorithm>
#include <cstring>
#include <chrono>
#include <cerrno>
#include <cmath>
#include <deque>
#include <sstream>
#include <stdexcept>

#include <fcntl.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

// Linux DMA-BUF / dma-heap 分配
#include <linux/dma-heap.h>
#include <linux/dma-buf.h>
#include <linux/videodev2.h>

// librga 2.0 im2d API
#include <im2d.hpp>
#include <rga.h>
#include <RockchipRga.h>

namespace rk3588 {
namespace engine {

// ============================================================================
// 常量定义
// ============================================================================

/** @brief IOCTL 重试次数 */
static constexpr int kIoctlRetries = 3;

/** @brief IOCTL 重试间隔 (us) */
static constexpr int kIoctlRetryUs = 500;

/** @brief V4L2 POLL 超时 (ms) */
static constexpr int kPollTimeoutMs = 3000;

/** @brief FPS 统计窗口 (帧数) */
static constexpr size_t kFpsWindow = 60;

// ============================================================================
// 辅助函数
// ============================================================================

/** @brief 带重试的 IOCTL 调用 */
static int Xioctl(int fd, unsigned long request, void* arg) {
  int ret;
  for (int i = 0; i < kIoctlRetries; ++i) {
    ret = ioctl(fd, request, arg);
    if (ret != -1 || (errno != EINTR && errno != EAGAIN)) {
      break;
    }
    usleep(kIoctlRetryUs);
  }
  return ret;
}

/** @brief V4L2 像素格式转 RGA 格式 */
static uint64_t V4l2ToRgaFormat(uint32_t v4l2_fmt) {
  switch (v4l2_fmt) {
    case V4L2_PIX_FMT_NV12:     return RK_FORMAT_YCbCr_420_SP;
    case V4L2_PIX_FMT_NV21:     return RK_FORMAT_YCrCb_420_SP;
    case V4L2_PIX_FMT_NV16:     return RK_FORMAT_YCbCr_422_SP;
    case V4L2_PIX_FMT_YUYV:     return RK_FORMAT_YUYV_422;
    case V4L2_PIX_FMT_RGB32:    return RK_FORMAT_RGB_888;
    case V4L2_PIX_FMT_BGR32:    return RK_FORMAT_BGR_888;
    case V4L2_PIX_FMT_RGBA32:   // fall through
    case V4L2_PIX_FMT_ABGR32:   return RK_FORMAT_RGBA_8888;
    default:                     return RK_FORMAT_YCbCr_420_SP;
  }
}

/** @brief V4L2 像素格式名称 (调试用) */
static const char* V4l2FmtName(uint32_t fmt) {
  switch (fmt) {
    case V4L2_PIX_FMT_NV12:    return "NV12";
    case V4L2_PIX_FMT_NV21:    return "NV21";
    case V4L2_PIX_FMT_NV16:    return "NV16";
    case V4L2_PIX_FMT_YUYV:    return "YUYV";
    case V4L2_PIX_FMT_RGB32:   return "RGB888";
    case V4L2_PIX_FMT_BGR32:   return "BGR888";
    case V4L2_PIX_FMT_RGBA32:  return "RGBA8888";
    case V4L2_PIX_FMT_ABGR32:  return "ABGR8888";
    case V4L2_PIX_FMT_MJPEG:   return "MJPEG";
    default:                    return "UNKNOWN";
  }
}

// ============================================================================
// PIMPL 实现结构
// ============================================================================

struct RgaPipeline::Impl {
  // ── 配置 ──
  CameraConfig cam_cfg;
  RgaConvertConfig rga_cfg;

  // ── V4L2 状态 ──
  int v4l2_fd = -1;
  bool capturing = false;

  // V4L2 缓冲区 (使用 DMA-BUF 或 mmap)
  std::vector<FrameBuffer> buffers;

  // ── RGA 状态 ──
  bool rga_available = false;

  // 输出 DMA-BUF (预分配，RGA 写入)
  int output_dma_fd = -1;
  void* output_dma_virt = nullptr;
  uint32_t output_dma_size = 0;

  // RGA 输出目标 buffer (使用 imimport 包装 DMA-BUF)
  rga_buffer_t dst_buf;

  // ── 状态 ──
  bool initialized = false;

  // ── 性能统计 ──
  std::deque<double> capture_latencies;
  std::chrono::steady_clock::time_point last_fps_time;
  uint32_t frame_count = 0;
};

// ============================================================================
// 构造 / 析构
// ============================================================================

RgaPipeline::RgaPipeline(const CameraConfig& cam_cfg,
                         const RgaConvertConfig& rga_cfg)
    : impl_(std::make_unique<Impl>()) {
  impl_->cam_cfg = cam_cfg;
  impl_->rga_cfg = rga_cfg;
}

RgaPipeline::~RgaPipeline() {
  Stop();
}

// ============================================================================
// 初始化主流程
// ============================================================================

bool RgaPipeline::Init() {
  if (impl_->initialized) {
    return true;
  }

  // 1. 打开 V4L2 设备
  if (!OpenDevice()) {
    return false;
  }

  // 2. 设置采集格式
  if (!SetFormat()) {
    Stop();
    return false;
  }

  // 3. 请求缓冲区
  if (!RequestBuffers()) {
    Stop();
    return false;
  }

  // 4. 分配 RGA 输出 DMA-BUF
  if (!AllocOutputDmaBuf()) {
    Stop();
    return false;
  }

  // 5. 队列缓冲区，开始采集
  if (!StartCapture()) {
    Stop();
    return false;
  }

  impl_->initialized = true;
  impl_->rga_available = true;
  impl_->last_fps_time = std::chrono::steady_clock::now();
  return true;
}

// ============================================================================
// V4L2 设备操作
// ============================================================================

bool RgaPipeline::OpenDevice() {
  const auto& dev = impl_->cam_cfg.device;

  impl_->v4l2_fd = open(dev.c_str(), O_RDWR | O_NONBLOCK, 0);
  if (impl_->v4l2_fd < 0) {
    return false;
  }

  // 查询设备能力
  struct v4l2_capability cap;
  memset(&cap, 0, sizeof(cap));
  if (Xioctl(impl_->v4l2_fd, VIDIOC_QUERYCAP, &cap) < 0) {
    return false;
  }

  // 验证设备类型
  if (!(cap.capabilities & V4L2_CAP_VIDEO_CAPTURE)) {
    return false;
  }
  if (!(cap.capabilities & V4L2_CAP_STREAMING)) {
    return false;
  }

  return true;
}

bool RgaPipeline::SetFormat() {
  const auto& cfg = impl_->cam_cfg;

  struct v4l2_format fmt;
  memset(&fmt, 0, sizeof(fmt));
  fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
  fmt.fmt.pix.width = cfg.width;
  fmt.fmt.pix.height = cfg.height;
  fmt.fmt.pix.pixelformat = cfg.pixelformat;
  fmt.fmt.pix.field = V4L2_FIELD_NONE;

  // 尝试设置格式
  if (Xioctl(impl_->v4l2_fd, VIDIOC_S_FMT, &fmt) < 0) {
    return false;
  }

  // 读取实际设置的格式（驱动可能调整分辨率）
  // 更新配置以反映实际值

  // 设置帧率
  struct v4l2_streamparm parm;
  memset(&parm, 0, sizeof(parm));
  parm.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
  parm.parm.capture.timeperframe.numerator = 1;
  parm.parm.capture.timeperframe.denominator = cfg.fps;
  Xioctl(impl_->v4l2_fd, VIDIOC_S_PARM, &parm);  // best-effort

  return true;
}

bool RgaPipeline::RequestBuffers() {
  const auto& cfg = impl_->cam_cfg;

  struct v4l2_requestbuffers req;
  memset(&req, 0, sizeof(req));
  req.count = cfg.buffer_count;
  req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
  req.memory = cfg.use_dmabuf ? V4L2_MEMORY_DMABUF : V4L2_MEMORY_MMAP;

  if (Xioctl(impl_->v4l2_fd, VIDIOC_REQBUFS, &req) < 0) {
    return false;
  }

  if (req.count < 2) {
    return false;
  }

  // 查询并映射所有缓冲区
  impl_->buffers.resize(req.count);
  for (uint32_t i = 0; i < req.count; ++i) {
    struct v4l2_buffer buf;
    struct v4l2_plane planes[VIDEO_MAX_PLANES];
    memset(&buf, 0, sizeof(buf));
    memset(&planes, 0, sizeof(planes));

    buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    buf.memory = req.memory;
    buf.index = i;
    buf.length = 1;
    buf.m.planes = planes;

    if (Xioctl(impl_->v4l2_fd, VIDIOC_QUERYBUF, &buf) < 0) {
      return false;
    }

    FrameBuffer fb;
    fb.index = i;
    fb.length = planes[0].length;
    fb.bytesused = 0;

    if (cfg.use_dmabuf) {
      // DMA-BUF 模式: 分配外部 DMA-BUF 并通过 VIDIOC_EXPBUF 导出
      // 部分驱动直接通过 QBUF 传入 dmabuf fd
      fb.dma_fd = -1;  // 将在 DQBUF 时填充
      fb.start = nullptr;
    } else {
      // MMAP 模式
      fb.length = planes[0].length;
      fb.start = mmap(nullptr, fb.length,
                      PROT_READ | PROT_WRITE, MAP_SHARED,
                      impl_->v4l2_fd, planes[0].m.mem_offset);
      if (fb.start == MAP_FAILED) {
        return false;
      }
    }

    impl_->buffers[i] = fb;
  }

  return true;
}

bool RgaPipeline::StartCapture() {
  const auto& cfg = impl_->cam_cfg;
  enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;

  // 队列所有缓冲区
  for (uint32_t i = 0; i < impl_->buffers.size(); ++i) {
    struct v4l2_buffer buf;
    struct v4l2_plane planes[VIDEO_MAX_PLANES];
    memset(&buf, 0, sizeof(buf));
    memset(&planes, 0, sizeof(planes));

    buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    buf.memory = cfg.use_dmabuf ? V4L2_MEMORY_DMABUF : V4L2_MEMORY_MMAP;
    buf.index = i;
    buf.length = 1;
    buf.m.planes = planes;

    if (cfg.use_dmabuf) {
      // 使用外部分配的 DMA-BUF fd
      planes[0].m.fd = impl_->buffers[i].dma_fd;
      planes[0].length = impl_->buffers[i].length;
    }

    if (Xioctl(impl_->v4l2_fd, VIDIOC_QBUF, &buf) < 0) {
      return false;
    }
    impl_->buffers[i].state = BufferState::QUEUED;
  }

  // 启动采集流
  if (Xioctl(impl_->v4l2_fd, VIDIOC_STREAMON, &type) < 0) {
    return false;
  }

  impl_->capturing = true;
  return true;
}

// ============================================================================
// 帧采集 + RGA 转换 (核心方法)
// ============================================================================

PipelineFrame RgaPipeline::CaptureAndConvert() {
  PipelineFrame result;

  if (!impl_->initialized || !impl_->capturing) {
    return result;
  }

  // ── 1. V4L2 DQBUF: 等待并获取一帧 ──
  struct pollfd pfd;
  pfd.fd = impl_->v4l2_fd;
  pfd.events = POLLIN;

  int poll_ret = poll(&pfd, 1, kPollTimeoutMs);
  if (poll_ret <= 0) {
    return result;
  }

  struct v4l2_buffer buf;
  struct v4l2_plane planes[VIDEO_MAX_PLANES];
  memset(&buf, 0, sizeof(buf));
  memset(&planes, 0, sizeof(planes));
  buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
  buf.memory = impl_->cam_cfg.use_dmabuf ? V4L2_MEMORY_DMABUF : V4L2_MEMORY_MMAP;
  buf.length = 1;
  buf.m.planes = planes;

  if (Xioctl(impl_->v4l2_fd, VIDIOC_DQBUF, &buf) < 0) {
    return result;
  }

  uint32_t buf_idx = buf.index;
  auto& fb = impl_->buffers[buf_idx];
  fb.state = BufferState::DEQUEUED;
  fb.sequence = buf.sequence;
  fb.timestamp_ns = buf.timestamp.tv_sec * 1000000000ULL +
                    buf.timestamp.tv_usec * 1000ULL;
  fb.bytesused = planes[0].bytesused;

  // ── 2. RGA 格式转换: NV12 → RGB ──
  // 使用 im2d API 的 imimport → improcess → imexport 零拷贝路径

  // 2a. imimport: 将 V4L2 DMA-BUF 包装为 rga_buffer_t
  int src_dma_fd = -1;
  void* src_virt = nullptr;
  uint32_t src_size = 0;

  if (impl_->cam_cfg.use_dmabuf && planes[0].m.fd >= 0) {
    // 驱动返回了 DMA-BUF fd (通过 V4L2_MEMORY_DMABUF)
    src_dma_fd = planes[0].m.fd;
  } else if (fb.dma_fd >= 0) {
    // 使用预分配的 DMA-BUF
    src_dma_fd = fb.dma_fd;
  } else {
    // 回退: 使用 mmap 地址
    src_virt = fb.start;
  }

  rga_buffer_t src_buf;
  if (src_dma_fd >= 0) {
    // 通过 DMA-BUF fd 导入，零拷贝
    src_buf = imimport(src_dma_fd, src_size,
                       impl_->rga_cfg.src_width, impl_->rga_cfg.src_height,
                       V4l2ToRgaFormat(impl_->rga_cfg.src_format),
                       IM_DMA_BUF_IMPORT);
  } else if (src_virt) {
    src_buf = wrapbuffer_virtualaddr(src_virt,
                                     impl_->rga_cfg.src_width,
                                     impl_->rga_cfg.src_height,
                                     V4l2ToRgaFormat(impl_->rga_cfg.src_format));
  } else {
    // 无法获取源数据
    // 重新入队缓冲区
    struct v4l2_buffer rebuf;
    struct v4l2_plane re_planes[VIDEO_MAX_PLANES];
    memset(&rebuf, 0, sizeof(rebuf));
    memset(&re_planes, 0, sizeof(re_planes));
    rebuf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    rebuf.memory = impl_->cam_cfg.use_dmabuf ? V4L2_MEMORY_DMABUF : V4L2_MEMORY_MMAP;
    rebuf.index = buf_idx;
    rebuf.length = 1;
    rebuf.m.planes = re_planes;
    if (impl_->cam_cfg.use_dmabuf) {
      re_planes[0].m.fd = fb.dma_fd;
    }
    Xioctl(impl_->v4l2_fd, VIDIOC_QBUF, &rebuf);
    fb.state = BufferState::QUEUED;
    return result;
  }

  if (src_buf.handle <= 0) {
    // imimport 失败，重新入队
    struct v4l2_buffer rebuf;
    struct v4l2_plane re_planes[VIDEO_MAX_PLANES];
    memset(&rebuf, 0, sizeof(rebuf));
    memset(&re_planes, 0, sizeof(re_planes));
    rebuf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    rebuf.memory = impl_->cam_cfg.use_dmabuf ? V4L2_MEMORY_DMABUF : V4L2_MEMORY_MMAP;
    rebuf.index = buf_idx;
    rebuf.length = 1;
    rebuf.m.planes = re_planes;
    if (impl_->cam_cfg.use_dmabuf) {
      re_planes[0].m.fd = fb.dma_fd;
    }
    Xioctl(impl_->v4l2_fd, VIDIOC_QBUF, &rebuf);
    fb.state = BufferState::QUEUED;
    return result;
  }

  // 计算 letterbox 裁剪参数
  int crop_x = 0, crop_y = 0, crop_w = 0, crop_h = 0;
  if (impl_->rga_cfg.letterbox) {
    CalcLetterbox(impl_->rga_cfg.src_width, impl_->rga_cfg.src_height,
                  impl_->rga_cfg.dst_width, impl_->rga_cfg.dst_height,
                  crop_x, crop_y, crop_w, crop_h);
  }

  // 2b. improcess: 执行 NV12 → RGB 转换 + 缩放
  im_rect src_rect;
  if (impl_->rga_cfg.letterbox && crop_w > 0 && crop_h > 0) {
    src_rect = {crop_x, crop_y, crop_w, crop_h};
  } else {
    src_rect = {0, 0,
                static_cast<int>(impl_->rga_cfg.src_width),
                static_cast<int>(impl_->rga_cfg.src_height)};
  }

  im_rect dst_rect = {0, 0,
                      static_cast<int>(impl_->rga_cfg.dst_width),
                      static_cast<int>(impl_->rga_cfg.dst_height)};

  int ret = improcess(src_buf, impl_->dst_buf, src_rect, dst_rect,
                      IM_SYNC);
  if (ret != IM_STATUS_SUCCESS) {
    // improcess 失败: 释放资源
    imrelease(src_buf);

    // 重新入队缓冲区
    struct v4l2_buffer rebuf;
    struct v4l2_plane re_planes[VIDEO_MAX_PLANES];
    memset(&rebuf, 0, sizeof(rebuf));
    memset(&re_planes, 0, sizeof(re_planes));
    rebuf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    rebuf.memory = impl_->cam_cfg.use_dmabuf ? V4L2_MEMORY_DMABUF : V4L2_MEMORY_MMAP;
    rebuf.index = buf_idx;
    rebuf.length = 1;
    rebuf.m.planes = re_planes;
    if (impl_->cam_cfg.use_dmabuf) {
      re_planes[0].m.fd = fb.dma_fd;
    }
    Xioctl(impl_->v4l2_fd, VIDIOC_QBUF, &rebuf);
    fb.state = BufferState::QUEUED;
    return result;
  }

  // 释放源 RGA buffer (不释放 DMA-BUF, 只是减少引用计数)
  imrelease(src_buf);

  // 2c. imexport: 获取输出 DMA-BUF fd
  int out_fd = imexport(impl_->dst_buf, src_dma_fd);
  if (out_fd < 0) {
    // 如果 imexport 失败，使用预分配的 output_dma_fd 的 mmap 地址
    result.dma_fd = impl_->output_dma_fd;
    result.virt_addr = impl_->output_dma_virt;
  } else {
    result.dma_fd = out_fd;
    // virt_addr 在需要时才 mmap (通常 NPU 直接使用 fd)
    result.virt_addr = nullptr;
  }

  result.size = impl_->output_dma_size;
  result.width = impl_->rga_cfg.dst_width;
  result.height = impl_->rga_cfg.dst_height;
  result.sequence = fb.sequence;
  result.timestamp_ns = fb.timestamp_ns;

  // ── 3. 重新入队 V4L2 缓冲区 ──
  struct v4l2_buffer rebuf;
  struct v4l2_plane re_planes[VIDEO_MAX_PLANES];
  memset(&rebuf, 0, sizeof(rebuf));
  memset(&re_planes, 0, sizeof(re_planes));
  rebuf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
  rebuf.memory = impl_->cam_cfg.use_dmabuf ? V4L2_MEMORY_DMABUF : V4L2_MEMORY_MMAP;
  rebuf.index = buf_idx;
  rebuf.length = 1;
  rebuf.m.planes = re_planes;
  if (impl_->cam_cfg.use_dmabuf) {
    re_planes[0].m.fd = fb.dma_fd;
    re_planes[0].length = fb.length;
  }
  Xioctl(impl_->v4l2_fd, VIDIOC_QBUF, &rebuf);
  fb.state = BufferState::QUEUED;

  // ── 4. 更新 FPS 统计 ──
  impl_->frame_count++;
  auto now = std::chrono::steady_clock::now();
  double elapsed_ms = std::chrono::duration<double, std::milli>(
      now - impl_->last_fps_time).count();
  impl_->capture_latencies.push_back(elapsed_ms);
  if (impl_->capture_latencies.size() > kFpsWindow) {
    impl_->capture_latencies.pop_front();
  }

  return result;
}

// ============================================================================
// RGA 输出 DMA-BUF 分配
// ============================================================================

bool RgaPipeline::AllocOutputDmaBuf() {
  const auto& cfg = impl_->rga_cfg;

  // 计算输出大小: RGB888 = width * height * 3
  uint32_t dst_size = cfg.dst_width * cfg.dst_height * 3;

  // 尝试通过 dma-heap 分配物理连续内存
  const char* dma_heap_path = "/dev/dma_heap/system";

  // 首先尝试 system heap
  int heap_fd = open(dma_heap_path, O_RDWR | O_CLOEXEC);
  if (heap_fd >= 0) {
    struct dma_heap_allocation_data heap_data;
    memset(&heap_data, 0, sizeof(heap_data));
    heap_data.len = dst_size;
    heap_data.fd_flags = O_RDWR | O_CLOEXEC;
    heap_data.heap_flags = 0;

    int ret = ioctl(heap_fd, DMA_HEAP_IOCTL_ALLOC, &heap_data);
    close(heap_fd);

    if (ret == 0 && heap_data.fd >= 0) {
      // mmap 到用户空间 (可选，NPU 可以直接使用 fd)
      void* mapped = mmap(nullptr, dst_size, PROT_READ | PROT_WRITE,
                          MAP_SHARED, heap_data.fd, 0);
      if (mapped != MAP_FAILED) {
        impl_->output_dma_fd = heap_data.fd;
        impl_->output_dma_virt = mapped;
        impl_->output_dma_size = dst_size;
      } else {
        // 即使 mmap 失败，fd 仍然可用
        impl_->output_dma_fd = heap_data.fd;
        impl_->output_dma_virt = nullptr;
        impl_->output_dma_size = dst_size;
      }
    }
  }

  // 如果 dma-heap 失败，尝试 ION
  if (impl_->output_dma_fd < 0) {
    const char* ion_path = "/dev/ion";
    int ion_fd = open(ion_path, O_RDWR | O_CLOEXEC);
    if (ion_fd >= 0) {
      struct ion_allocation_data {
        uint64_t len;
        uint32_t heap_id_mask;
        uint32_t flags;
        uint32_t fd;
        uint32_t unused;
      };

      struct ion_allocation_data ion_data;
      memset(&ion_data, 0, sizeof(ion_data));
      ion_data.len = dst_size;
      ion_data.heap_id_mask = 1;  // ION_HEAP_TYPE_SYSTEM
      ion_data.flags = 0;

      int ret = ioctl(ion_fd, _IOWR('I', 0, struct ion_allocation_data), &ion_data);
      close(ion_fd);

      if (ret == 0 && ion_data.fd > 0) {
        void* mapped = mmap(nullptr, dst_size, PROT_READ | PROT_WRITE,
                            MAP_SHARED, ion_data.fd, 0);
        if (mapped != MAP_FAILED) {
          impl_->output_dma_fd = ion_data.fd;
          impl_->output_dma_virt = mapped;
          impl_->output_dma_size = dst_size;
        } else {
          impl_->output_dma_fd = ion_data.fd;
          impl_->output_dma_virt = nullptr;
          impl_->output_dma_size = dst_size;
        }
      }
    }
  }

  if (impl_->output_dma_fd < 0) {
    // 极端回退: 使用普通堆内存 (不推荐，失去零拷贝优势)
    impl_->output_dma_virt = malloc(dst_size);
    if (!impl_->output_dma_virt) {
      return false;
    }
    impl_->output_dma_size = dst_size;
  }

  // 用 imimport 将输出 DMA-BUF 包装为 rga_buffer_t
  impl_->dst_buf = imimport(impl_->output_dma_fd, impl_->output_dma_size,
                            cfg.dst_width, cfg.dst_height,
                            V4l2ToRgaFormat(cfg.dst_format),
                            IM_DMA_BUF_IMPORT);
  if (impl_->dst_buf.handle <= 0) {
    // fallback: wrap virtual address
    impl_->dst_buf = wrapbuffer_virtualaddr(impl_->output_dma_virt,
                                            cfg.dst_width, cfg.dst_height,
                                            V4l2ToRgaFormat(cfg.dst_format));
  }

  return true;
}

void RgaPipeline::FreeOutputDmaBuf() {
  if (impl_->dst_buf.handle > 0) {
    imrelease(impl_->dst_buf);
    impl_->dst_buf = {0};
  }

  if (impl_->output_dma_virt && impl_->output_dma_fd >= 0) {
    munmap(impl_->output_dma_virt, impl_->output_dma_size);
    close(impl_->output_dma_fd);
  } else if (impl_->output_dma_virt) {
    free(impl_->output_dma_virt);
  }

  impl_->output_dma_fd = -1;
  impl_->output_dma_virt = nullptr;
  impl_->output_dma_size = 0;
}

// ============================================================================
// 帧释放
// ============================================================================

void RgaPipeline::ReleaseFrame(PipelineFrame& frame) {
  if (frame.dma_fd >= 0) {
    // 如果 imexport 产生了新的 fd，需要关闭
    // 如果是预分配的 output_dma_fd，则不关闭
    if (frame.dma_fd != impl_->output_dma_fd) {
      if (frame.virt_addr) {
        munmap(frame.virt_addr, frame.size);
      }
      close(frame.dma_fd);
    }
  }

  frame.dma_fd = -1;
  frame.virt_addr = nullptr;
  frame.size = 0;
  frame.sequence = 0;
  frame.timestamp_ns = 0;
}

// ============================================================================
// 停止与资源释放
// ============================================================================

void RgaPipeline::Stop() {
  // 停止 V4L2 采集流
  if (impl_->capturing && impl_->v4l2_fd >= 0) {
    enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    Xioctl(impl_->v4l2_fd, VIDIOC_STREAMOFF, &type);
    impl_->capturing = false;
  }

  // 释放 V4L2 缓冲区
  for (auto& fb : impl_->buffers) {
    if (fb.start && fb.start != MAP_FAILED) {
      munmap(fb.start, fb.length);
      fb.start = nullptr;
    }
    if (fb.dma_fd >= 0) {
      close(fb.dma_fd);
      fb.dma_fd = -1;
    }
  }
  impl_->buffers.clear();

  // 释放 RGA 输出 DMA-BUF
  FreeOutputDmaBuf();

  // 关闭 V4L2 设备
  if (impl_->v4l2_fd >= 0) {
    close(impl_->v4l2_fd);
    impl_->v4l2_fd = -1;
  }

  impl_->initialized = false;
  impl_->rga_available = false;
}

// ============================================================================
// 状态查询
// ============================================================================

bool RgaPipeline::IsReady() const {
  return impl_->initialized && impl_->capturing;
}

double RgaPipeline::GetFps() const {
  if (impl_->capture_latencies.size() < 2) {
    return 0.0;
  }

  double total_ms = 0.0;
  for (double lat : impl_->capture_latencies) {
    total_ms += lat;
  }
  double avg_ms = total_ms / impl_->capture_latencies.size();
  return (avg_ms > 0.0) ? (1000.0 / avg_ms) : 0.0;
}

// ============================================================================
// 辅助方法
// ============================================================================

void RgaPipeline::CalcLetterbox(int src_w, int src_h, int dst_w, int dst_h,
                                int& crop_x, int& crop_y,
                                int& crop_w, int& crop_h) const {
  if (src_w <= 0 || src_h <= 0 || dst_w <= 0 || dst_h <= 0) {
    crop_x = 0;
    crop_y = 0;
    crop_w = src_w;
    crop_h = src_h;
    return;
  }

  float src_ratio = static_cast<float>(src_w) / src_h;
  float dst_ratio = static_cast<float>(dst_w) / dst_h;

  if (src_ratio > dst_ratio) {
    // 源更宽: 裁剪左右
    crop_h = src_h;
    crop_w = static_cast<int>(src_h * dst_ratio);
    crop_x = (src_w - crop_w) / 2;
    crop_y = 0;
  } else {
    // 源更高: 裁剪上下
    crop_w = src_w;
    crop_h = static_cast<int>(src_w / dst_ratio);
    crop_x = 0;
    crop_y = (src_h - crop_h) / 2;
  }
}

// ============================================================================
// 未使用的私有方法 (确保符号存在)
// ============================================================================

// 保留以下函数用于后续扩展

}  // namespace engine
}  // namespace rk3588
