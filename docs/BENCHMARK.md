# RK3588 MPP + NPU 推理性能基准

> NanoPC-T6 LTS, 6.1.141内核, RKNN 2.3.2, MPP硬解码
> 摄像头: RTSP 2688x1520 H.264 → 2688x1520 NV12
> 模型: yolov5s.rknn (14MB, ONNX导出, 静态shape)
> 日期: 2026-07-03

## 实测数据 (2026-07-03 最新)

| 版本 | 方案 | 解码 | 预处理 | NPU | 总延迟 | FPS | 说明 |
|------|------|------|--------|-----|--------|-----|------|
| v0 | OpenCV软解 | 35.6ms | 7.1ms | 18.6ms | 61.3ms | 13.8 | 基线 |
| v5 | MPP+DMA | <1ms | 10.4ms | 15.4ms | 25.8ms | 38.7 | +180% |
| **v7** | **MPP+NV12+BGR** | **0.2ms** | **8.7ms** | **15.4ms** | **24.2ms** | **41.2** | **当前最优** |
| v7单核 | MPP+NV12+BGR | 0.2ms | 7.6ms | 20.9ms | 28.7ms | 34.8 | 单核性能 |
| v7b | YUV2RGB直转 | 0.2ms | 9.1ms | 15.4ms | 24.7ms | 40.4 | 与v7持平 |
| v8 | RGA ctypes | 0.2ms | 10.5ms | 14.2ms | 24.9ms | 40.1 | RGA需调参 |
| v9 | GST管线缩放 | 0.1ms | 1.1ms | 29.3ms | 30.5ms | 32.7 | NPU对齐问题 |

## 瓶颈分析

- **解码**: MPP硬解码 0.2ms ✅ 近乎零开销
- **预处理**: cv2 NV12→BGR→resize 8.7ms (占36%) 🔴 主瓶颈
- **NPU推理**: 15.4ms (占64%) ⚠️ 可通过轻量模型优化

## 优化路线

### 短期 (<1周)
1. ✅ MPP硬解码 + DMA零拷贝 —— 已完成 (v7)
2. 🔄 yolov5n轻量模型 —— 目标NPU 15ms→8ms
3. 🔄 RGA硬件NV12→RGB —— 目标预处理 8.7ms→2ms

### 中期 (<1月)
4. RGA OSD叠加检测框(硬件绘制)
5. NPU多模型流水线(batch调度)
6. systemd服务化 + Web Dashboard

### 目标
- **当前**: 41.2 FPS / 24.2ms
- **短期目标**: 55+ FPS / <12ms (yolov5n + RGA)
- **中长期目标**: 60+ FPS (全硬件路径)

## 环境信息

- 板卡: FriendlyElec NanoPC-T6 LTS
- 内存: 8GB LPDDR4X
- 系统: Debian 11, Linux 6.1.141
- NPU驱动: 0.9.8
- RKNN: librknnrt 2.3.2
- MPP: librockchip_mpp.so.1
- RGA: librga2 2.2.0-1
