# AI 视觉流水线教程

> 🎯 从 RTSP 相机到 NPU 推理再到工业协议上报的完整流水线

## 流水线架构

```
┌──────────┐    ┌──────────────┐    ┌───────────┐    ┌──────────────┐
│  RTSP/   │───▶│ 预处理 (RGA)  │───▶│ NPU 推理  │───▶│ 后处理/绘图   │
│  Camera  │    │ resize+fmt   │    │ YOLOv5/8  │    │ NMS+bbox     │
└──────────┘    └──────────────┘    └───────────┘    └──────┬───────┘
                  DMA-BUF 零拷贝                      │
                                    ┌─────────────────┴──────┐
                                    │  Modbus / OPC UA 上报  │
                                    │  Dashboard 可视化      │
                                    └────────────────────────┘
```

## 1. 模型准备

### YOLOv5s (推荐入门)

```bash
# 下载预转换 RKNN 模型
wget https://github.com/airockchip/rknn_model_zoo/releases/download/v2.0.0/yolov5s-640-640.rknn
# 或使用项目内置
ls examples/yolov5-demo/yolov5s-640-640.rknn
```

### 自己转换模型

```python
# convert_model.py
from rknn.api import RKNN

rknn = RKNN()
# 配置
rknn.config(
    mean_values=[[0, 0, 0]],
    std_values=[[255, 255, 255]],
    target_platform="rk3588"
)
# 加载 ONNX
ret = rknn.load_onnx(model="yolov5s.onnx")
# 构建
ret = rknn.build(do_quantization=True, dataset="dataset.txt")
# 导出
ret = rknn.export_rknn("yolov5s.rknn")
rknn.release()
```

## 2. 推理引擎使用

```python
import cv2
import numpy as np
from rk3588_engine import Engine, Detection

# 加载模型 (context manager 自动释放)
with Engine("yolov5s.rknn", npu_core=-1, enable_profiling=True) as eng:
    cap = cv2.VideoCapture("rtsp://192.168.1.100:554/stream")

    while True:
        ret, frame = cap.read()
        if not ret:
            break

        # 推理 — frame 零拷贝进入 NPU
        detections = eng.infer(frame)

        # 绘制结果
        for d in detections:
            if d.confidence > 0.5:
                x1, y1, x2, y2 = d.bbox
                cv2.rectangle(frame, (x1, y1), (x2, y2), (0, 255, 0), 2)
                cv2.putText(frame, f"{d.label} {d.confidence:.2f}",
                           (x1, y1-10), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0,255,0), 2)

        # FPS 显示
        cv2.putText(frame, f"FPS: {eng.stats.fps:.1f}",
                   (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0,255,255), 2)

        cv2.imshow("AI Vision", frame)
        if cv2.waitKey(1) & 0xFF == ord('q'):
            break

    cap.release()
```

## 3. 生产级流水线

使用 `prod_pipeline.py`（项目已提供）：

```bash
python3 inference/ai-vision/prod_pipeline.py \
    --source rtsp://192.168.1.100:554/stream \
    --model yolov5s-640-640.rknn \
    --conf 0.5 \
    --npu-core 0 \
    --modbus-port 502 \
    --opcua-port 4840
```

### YAML 配置方式

```yaml
# configs/engine.yaml
source:
  type: rtsp
  uri: "rtsp://192.168.1.100:554/stream"

model:
  path: "yolov5s-640-640.rknn"
  input_size: [640, 640]
  confidence_threshold: 0.5
  nms_threshold: 0.45

npu:
  core: 0           # 0,1,2 指定核心; -1 自动
  batch_size: 1

output:
  modbus: {enabled: true, port: 502}
  opcua: {enabled: true, port: 4840}
  dashboard: {enabled: true, port: 8080}
  rtsp_out: {enabled: false}      # 可输出带检测框的 RTSP 流
```

## 4. 性能优化技巧

### 4.1 RGA 硬件预处理

```python
import rga

# RGA 硬件 resize + 颜色转换 (不占 CPU)
rga.resize(frame, (640, 640), fmt="rgb888", dst=engine.input_buffer)
```

### 4.2 多核心负载均衡

```python
from rk3588_engine import Engine, NPUScheduler

scheduler = NPUScheduler()

# 核心 0: 主推理
with Engine("yolov5s.rknn", npu_core=0) as eng_main:
    # 核心 1: 辅助模型 (如车牌识别)
    with Engine("lpr.rknn", npu_core=1) as eng_lpr:
        detections = eng_main.infer(frame)
        for d in detections:
            if d.label == "car":
                plate = eng_lpr.infer(crop_region(frame, d.bbox))
```

### 4.3 Pipeline 预取

```python
# prod_pipeline.py 内置双缓冲预取
# Frame N 推理时，Frame N+1 已被 RGA 预处理完成
pipeline = ProductionPipeline(config="engine.yaml")
pipeline.run(source="rtsp://...")  # 自动双缓冲
```

## 5. 性能基准

| 模型 | 输入尺寸 | NPU 推理 (ms) | 端到端 FPS | 说明 |
|------|----------|--------------|-----------|------|
| YOLOv5s | 640×640 | 21.7 | 25.7 | 推荐入门 |
| YOLOv5n | 640×640 | 15.2 | 30.1 | 更快，精度略低 |
| YOLOv8n | 640×640 | 16.8 | 28.5 | mAP 更高 |
| YOLOv5m | 640×640 | 38.5 | 18.2 | 更高精度 |

> 硬件: RK3588 (LubanCat-5), PREEMPT_RT 内核, CPU 4-7 隔离给实时任务。

## 6. 故障排查

| 症状 | 可能原因 | 解决 |
|------|----------|------|
| `ImportError: librknnrt.so` | NPU 库未安装 | `sudo ldconfig && ldconfig -p | grep rknn` |
| 推理结果全空 | 输入格式不对 | 确认 BGR/RGB, uint8 dtype |
| FPS 突然掉到 <10 | 散热降频 | `cat /sys/class/thermal/thermal_zone0/temp` |
| RGA 报错 | 驱动未加载 | `sudo modprobe rga` |
| OOM | 内存不足 | 减小 batch, 检查 `free -h` |
