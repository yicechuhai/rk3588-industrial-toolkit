/**
 * @file rga_pipeline.cpp
 * @brief RGA 硬件加速流水线实现 — V4L2 采集 → RGA 格式转换 → NPU 推理输入
 *
 * 流水线:
 *   /dev/video0 (V4L2, NV12, MMAP + EXPBUF → DMA-BUF)
 *       ↓ V4L2 DQBUF → mmap buf
 *    ExportV4l2DmaBuf() → DMA-BUF fd
 *       ↓
 *    importbuffer_fd(fd) → rga_buffer_handle_t
 *       ↓
 *    wrapbuffer_handle(handle) → rga_buffer_t (src)
 *       ↓
 *    improcess(NV12 → RGB, letterbox crop + resize)
 *       ↓
 *    output DMA-BUF fd → PipelineFrame.dma_fd → NPU 输入
 *
 * 全程零拷贝: RGA 直接在 DMA-BUF 上操作，不经过 CPU memcpy。
 *
 * im2d API 参考:
 *   - importbuffer_fd()    导入外部 DMA-BUF 到 RGA 驱动
 *   - wrapbuffer_handle()  包装 rga_buffer_handle → rga_buffer_t
 *   - improcess()          综合处理 (crop + resize + cvtcolor)
 *   - releasebuffer_handle() 释放导入的 buffer handle
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

// DMA-BUF / dma-heap 分配
#include <linux/dma-heap.h>
#include <linux/dma-buf.h>
#include <linux/videodev2.h>

#ifndef VIDIOC_EXPBUF
struct v4l2_exportbuffer {
  uint32_t fd;
  uint32_t type;
  uint32_t index;
  uint32_t plane;
  uint32_t reserved;
};
#define VIDIOC_EXPBUF _IOWR('V', 0x10, struct v4l2_exportbuffer)
#endif

// librga 2.0 im2d API (C++ 封装)
// RGA im2d headers use GCC extensions (braced-groups, zero-length arrays)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wpedantic"
#include <im2d.hpp>
#include <rga.h>
#pragma GCC diagnostic pop
#include <im2d_type.h>

namespace rk3588 {
namespace engine {

// ============================================================================
// 常量定义
// ============================================================================

static constexpr int kIoctlRetries = 3;
static constexpr int kIoctlRetryUs = 500;
static constexpr int kPollTimeoutMs = 3000;
static constexpr size_t kFpsWindow = 60;

// ============================================================================
// 辅助函数
// ============================================================================

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

static int V4l2ToRgaFormat(uint32_t v4l2_fmt) {
  switch (v4l2_fmt) {
    case V4L2_PIX_FMT_NV12:     return RK_FORMAT_YCbCr_420_SP;
    case V4L2_PIX_FMT_NV21:     return RK_FORMAT_YCrCb_420_SP;
    case V4L2_PIX_FMT_NV16:     return RK_FORMAT_YCbCr_422_SP;
    case V4L2_PIX_FMT_YUYV:     return RK_FORMAT_YUYV_422;
    case V4L2_PIX_FMT_RGB32:    return RK_FORMAT_RGB_888;
    case V4L2_PIX_FMT_BGR32:    return RK_FORMAT_BGR_888;
    case V4L2_PIX_FMT_RGBA32:
    case V4L2_PIX_FMT_ABGR32:   return RK_FORMAT_RGBA_8888;
    default:                     return RK_FORMAT_YCbCr_420_SP;
  }
}

#if 0  // unused; kept for debugging
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
#endif  // V4l2FmtName

static int ExportV4l2DmaBuf(int v4l2_fd, uint32_t buf_idx) {
  struct v4l2_exportbuffer exp;
  memset(&exp, 0, sizeof(exp));
  exp.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
  exp.index = buf_idx;
  exp.plane = 0;
  if (Xioctl(v4l2_fd, VIDIOC_EXPBUF, &exp) < 0) {
    return -1;
  }
  return exp.fd;
}

static inline uint32_t Nv12FrameSize(uint32_t width, uint32_t height) {
  return width * height * 3 / 2;
}

static inline uint32_t RgbFrameSize(uint32_t width, uint32_t height) {
  return width * height * 3;
}

// ============================================================================
// PIMPL 实现结构
// ============================================================================

struct RgaPipeline::Impl {
  CameraConfig cam_cfg;
  RgaConvertConfig rga_cfg;

  int v4l2_fd = -1;
  bool capturing = false;
  std::vector<FrameBuffer> buffers;

  bool rga_available = false;

  int output_dma_fd = -1;
  void* output_dma_virt = nullptr;
  uint32_t output_dma_size = 0;

  rga_buffer_handle_t output_handle = 0;
  rga_buffer_t dst_buf;

  bool initialized = false;

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
  if (impl_->rga_cfg.src_width == 0) {
    impl_->rga_cfg.src_width = cam_cfg.width;
  }
  if (impl_->rga_cfg.src_height == 0) {
    impl_->rga_cfg.src_height = cam_cfg.height;
  }
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
  if (!OpenDevice()) {
    return false;
  }
  if (!SetFormat()) {
    Stop();
    return false;
  }
  if (!RequestBuffers()) {
    Stop();
    return false;
  }
  if (!AllocOutputDmaBuf()) {
    Stop();
    return false;
  }
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
  struct v4l2_capability cap;
  memset(&cap, 0, sizeof(cap));
  if (Xioctl(impl_->v4l2_fd, VIDIOC_QUERYCAP, &cap) < 0) {
    close(impl_->v4l2_fd);
    impl_->v4l2_fd = -1;
    return false;
  }
  if (!(cap.capabilities & V4L2_CAP_VIDEO_CAPTURE)) {
    close(impl_->v4l2_fd);
    impl_->v4l2_fd = -1;
    return false;
  }
  if (!(cap.capabilities & V4L2_CAP_STREAMING)) {
    close(impl_->v4l2_fd);
    impl_->v4l2_fd = -1;
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
  if (Xioctl(impl_->v4l2_fd, VIDIOC_S_FMT, &fmt) < 0) {
    return false;
  }
  struct v4l2_streamparm parm;
  memset(&parm, 0, sizeof(parm));
  parm.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
  parm.parm.capture.timeperframe.numerator = 1;
  parm.parm.capture.timeperframe.denominator = cfg.fps;
  Xioctl(impl_->v4l2_fd, VIDIOC_S_PARM, &parm);
  return true;
}

bool RgaPipeline::RequestBuffers() {
  const auto& cfg = impl_->cam_cfg;
  struct v4l2_requestbuffers req;
  memset(&req, 0, sizeof(req));
  req.count = cfg.buffer_count;
  req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
  req.memory = V4L2_MEMORY_MMAP;
  if (Xioctl(impl_->v4l2_fd, VIDIOC_REQBUFS, &req) < 0) {
    return false;
  }
  if (req.count < 2) {
    return false;
  }
  impl_->buffers.resize(req.count);
  for (uint32_t i = 0; i < req.count; ++i) {
    struct v4l2_buffer buf;
    struct v4l2_plane planes[VIDEO_MAX_PLANES];
    memset(&buf, 0, sizeof(buf));
    memset(&planes, 0, sizeof(planes));
    buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    buf.memory = V4L2_MEMORY_MMAP;
    buf.index = i;
    buf.length = 1;
    buf.m.planes = planes;
    if (Xioctl(impl_->v4l2_fd, VIDIOC_QUERYBUF, &buf) < 0) {
      return false;
    }
    FrameBuffer fb;
    fb.index = i;
    fb.length = planes[0].length;
    fb.start = mmap(nullptr, fb.length,
                    PROT_READ | PROT_WRITE, MAP_SHARED,
                    impl_->v4l2_fd, planes[0].m.mem_offset);
    if (fb.start == MAP_FAILED) {
      return false;
    }
    fb.state = BufferState::UNUSED;
    if (impl_->cam_cfg.use_dmabuf) {
      fb.dma_fd = ExportV4l2DmaBuf(impl_->v4l2_fd, i);
    }
    impl_->buffers[i] = fb;
  }
  return true;
}

bool RgaPipeline::StartCapture() {
  enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
  for (uint32_t i = 0; i < impl_->buffers.size(); ++i) {
    struct v4l2_buffer buf;
    struct v4l2_plane planes[VIDEO_MAX_PLANES];
    memset(&buf, 0, sizeof(buf));
    memset(&planes, 0, sizeof(planes));
    buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    buf.memory = V4L2_MEMORY_MMAP;
    buf.index = i;
    buf.length = 1;
    buf.m.planes = planes;
    if (Xioctl(impl_->v4l2_fd, VIDIOC_QBUF, &buf) < 0) {
      return false;
    }
    impl_->buffers[i].state = BufferState::QUEUED;
  }
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

  // 1. V4L2 DQBUF
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
  buf.memory = V4L2_MEMORY_MMAP;
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

  // 2. RGA 格式转换: NV12 → RGB
  int src_fd = fb.dma_fd;
  void* src_virt = fb.start;
  if (src_fd < 0 && impl_->cam_cfg.use_dmabuf) {
    src_fd = ExportV4l2DmaBuf(impl_->v4l2_fd, buf_idx);
    if (src_fd >= 0) {
      fb.dma_fd = src_fd;
    }
  }

  rga_buffer_handle_t src_handle = 0;
  rga_buffer_t src_buf;
  if (src_fd >= 0) {
    src_handle = importbuffer_fd(src_fd,
                                 static_cast<int>(Nv12FrameSize(
                                     impl_->rga_cfg.src_width,
                                     impl_->rga_cfg.src_height)));
    if (src_handle > 0) {
      src_buf = wrapbuffer_handle(src_handle,
                                  static_cast<int>(impl_->rga_cfg.src_width),
                                  static_cast<int>(impl_->rga_cfg.src_height),
                                  V4l2ToRgaFormat(impl_->rga_cfg.src_format));
    }
  }
  if (src_handle <= 0 && src_virt) {
    src_buf = wrapbuffer_virtualaddr(src_virt,
                                     impl_->rga_cfg.src_width,
                                     impl_->rga_cfg.src_height,
                                     V4l2ToRgaFormat(impl_->rga_cfg.src_format));
  }
  if (src_buf.handle <= 0) {
    RequeueBuffer(buf_idx);
    fb.state = BufferState::QUEUED;
    return result;
  }

  int crop_x = 0, crop_y = 0, crop_w = 0, crop_h = 0;
  if (impl_->rga_cfg.letterbox) {
    CalcLetterbox(static_cast<int>(impl_->rga_cfg.src_width),
                  static_cast<int>(impl_->rga_cfg.src_height),
                  static_cast<int>(impl_->rga_cfg.dst_width),
                  static_cast<int>(impl_->rga_cfg.dst_height),
                  crop_x, crop_y, crop_w, crop_h);
  }

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

  IM_STATUS status = improcess(src_buf, impl_->dst_buf, rga_buffer_t(),
                               src_rect, dst_rect, im_rect(),
                               -1, nullptr, nullptr, IM_SYNC);

  if (src_handle > 0) {
    releasebuffer_handle(src_handle);
  }
  if (status != IM_STATUS_SUCCESS) {
    RequeueBuffer(buf_idx);
    fb.state = BufferState::QUEUED;
    return result;
  }

  result.dma_fd = impl_->output_dma_fd;
  result.virt_addr = impl_->output_dma_virt;
  result.size = impl_->output_dma_size;
  result.width = impl_->rga_cfg.dst_width;
  result.height = impl_->rga_cfg.dst_height;
  result.sequence = fb.sequence;
  result.timestamp_ns = fb.timestamp_ns;

  RequeueBuffer(buf_idx);
  fb.state = BufferState::QUEUED;

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
// V4L2 缓冲区重新入队
// ============================================================================

void RgaPipeline::RequeueBuffer(uint32_t buf_idx) {
  if (impl_->v4l2_fd < 0) return;
  struct v4l2_buffer rebuf;
  struct v4l2_plane re_planes[VIDEO_MAX_PLANES];
  memset(&rebuf, 0, sizeof(rebuf));
  memset(&re_planes, 0, sizeof(re_planes));
  rebuf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
  rebuf.memory = V4L2_MEMORY_MMAP;
  rebuf.index = buf_idx;
  rebuf.length = 1;
  rebuf.m.planes = re_planes;
  Xioctl(impl_->v4l2_fd, VIDIOC_QBUF, &rebuf);
  if (buf_idx < impl_->buffers.size()) {
    impl_->buffers[buf_idx].state = BufferState::QUEUED;
  }
}

// ============================================================================
// RGA 输出 DMA-BUF 分配
// ============================================================================

bool RgaPipeline::AllocOutputDmaBuf() {
  const auto& cfg = impl_->rga_cfg;
  uint32_t dst_size = RgbFrameSize(cfg.dst_width, cfg.dst_height);
  int dst_format = V4l2ToRgaFormat(cfg.dst_format);

  const char* dma_heap_path = "/dev/dma_heap/system";
  int heap_fd = open(dma_heap_path, O_RDWR | O_CLOEXEC);
  if (heap_fd >= 0) {
    struct dma_heap_allocation_data heap_data;
    memset(&heap_data, 0, sizeof(heap_data));
    heap_data.len = dst_size;
    heap_data.fd_flags = O_RDWR | O_CLOEXEC;
    heap_data.heap_flags = 0;
    int ret = ioctl(heap_fd, DMA_HEAP_IOCTL_ALLOC, &heap_data);
    close(heap_fd);
    if (ret == 0) {  // heap_data.fd is unsigned (dma_heap_allocation_data.fd is __u32)
      void* mapped = mmap(nullptr, dst_size, PROT_READ | PROT_WRITE,
                          MAP_SHARED, heap_data.fd, 0);
      if (mapped != MAP_FAILED) {
        impl_->output_dma_fd = heap_data.fd;
        impl_->output_dma_virt = mapped;
        impl_->output_dma_size = dst_size;
      } else {
        impl_->output_dma_fd = heap_data.fd;
        impl_->output_dma_virt = nullptr;
        impl_->output_dma_size = dst_size;
      }
    }
  }

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
      ion_data.heap_id_mask = 1;
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
    impl_->output_dma_virt = malloc(dst_size);
    if (!impl_->output_dma_virt) {
      return false;
    }
    impl_->output_dma_size = dst_size;
  }

  if (impl_->output_dma_fd >= 0) {
    impl_->output_handle = importbuffer_fd(impl_->output_dma_fd,
                                           static_cast<int>(dst_size));
    if (impl_->output_handle > 0) {
      impl_->dst_buf = wrapbuffer_handle(impl_->output_handle,
                                         cfg.dst_width, cfg.dst_height,
                                         dst_format);
    }
  }
  if (impl_->dst_buf.handle <= 0) {
    impl_->dst_buf = wrapbuffer_virtualaddr(impl_->output_dma_virt,
                                            cfg.dst_width, cfg.dst_height,
                                            dst_format);
  }
  if (impl_->dst_buf.handle <= 0) {
    return false;
  }
  return true;
}

void RgaPipeline::FreeOutputDmaBuf() {
  if (impl_->output_handle > 0) {
    releasebuffer_handle(impl_->output_handle);
    impl_->output_handle = 0;
  }
  memset(&impl_->dst_buf, 0, sizeof(impl_->dst_buf));
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
  frame.dma_fd = -1;
  frame.virt_addr = nullptr;
  frame.size = 0;
  frame.width = 0;
  frame.height = 0;
  frame.sequence = 0;
  frame.timestamp_ns = 0;
}

// ============================================================================
// 停止与资源释放
// ============================================================================

void RgaPipeline::Stop() {
  if (impl_->capturing && impl_->v4l2_fd >= 0) {
    enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    Xioctl(impl_->v4l2_fd, VIDIOC_STREAMOFF, &type);
    impl_->capturing = false;
  }
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
  FreeOutputDmaBuf();
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
    crop_x = 0; crop_y = 0; crop_w = src_w; crop_h = src_h;
    return;
  }
  float src_ratio = static_cast<float>(src_w) / src_h;
  float dst_ratio = static_cast<float>(dst_w) / dst_h;
  if (src_ratio > dst_ratio) {
    crop_h = src_h;
    crop_w = static_cast<int>(src_h * dst_ratio);
    crop_x = (src_w - crop_w) / 2;
    crop_y = 0;
  } else {
    crop_w = src_w;
    crop_h = static_cast<int>(src_w / dst_ratio);
    crop_x = 0;
    crop_y = (src_h - crop_h) / 2;
  }
}

}  // namespace engine
}  // namespace rk3588
