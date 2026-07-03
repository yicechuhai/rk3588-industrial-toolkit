# 推理引擎 API (inference-api)

> **语言**: Python (pybind11 绑定 C++ 核心) / C++  
> **依赖**: `libengine.so`, `librknnrt.so`, `librga.so`

## 核心类

### Engine

```python
class Engine:
    """NPU 推理引擎 — 支持零拷贝 DMA-BUF 输入"""
    
    def __init__(self, model_path: str, 
                 npu_core: int = -1,      # -1=自动, 0-2=指定核心
                 enable_profiling: bool = False):
        """加载 RKNN 模型并初始化 NPU"""
        ...
    
    def infer(self, frame: np.ndarray | int) -> list[Detection]:
        """单帧推理
        Args:
            frame: np.ndarray (H,W,3) 或 DMA-BUF fd (整数)
        Returns:
            检测结果列表
        """
        ...
    
    def infer_batch(self, frames: list[np.ndarray]) -> list[list[Detection]]:
        """批量推理（自动拼合）"""
        ...
    
    def close(self):
        """释放 NPU 资源"""
        ...
    
    # Context Manager support
    def __enter__(self): return self
    def __exit__(self, *args): self.close()
```

### Detection

```python
@dataclass
class Detection:
    """单次检测结果"""
    class_id: int
    label: str
    confidence: float
    bbox: tuple[int, int, int, int]  # x1, y1, x2, y2
```

### Stats

```python
@dataclass
class Stats:
    """推理性能统计"""
    inference_ms: float       # NPU 推理耗时 (ms)
    preprocess_ms: float      # 预处理耗时
    postprocess_ms: float     # 后处理耗时
    total_ms: float           # 端到端耗时
    fps: float                # 实时帧率
```

### ModelLoader

```python
class ModelLoader:
    """模型格式工厂"""
    
    @staticmethod
    def load(model_path: str) -> Engine:
        """自动检测格式并加载
        Support: .rknn | .onnx (自动转换) | .pt (自动转换)
        """
        ...
    
    @staticmethod
    def convert(input_path: str, output_path: str,
                target: str = "rk3588", quantize: bool = True):
        """模型格式转换 (ONNX/PyTorch → RKNN)"""
        ...
```

### Pipeline

```python
class ProductionPipeline:
    """生产级 AI 视觉流水线"""
    
    def __init__(self, config_path: str = "engine.yaml"):
        """从 YAML 加载完整流水线配置"""
        ...
    
    def run(self, source: str):
        """运行流水线
        Args:
            source: "rtsp://..." | "/dev/video0" | "0" (USB cam)
        """
        ...
```

## NumPy 零拷贝

```python
# 标准用法：自动零拷贝
frame = cap.read()  # np.ndarray (1080, 1920, 3), dtype=uint8
results = engine.infer(frame)  # 通过 DMA-BUF 传递, 无需拷贝

# 手动 DMA-BUF
import rga
fd = rga.numpy_to_dmabuf(frame)  # 获取文件描述符
results = engine.infer(fd)       # 直接传递 fd
```

## 错误码

| 错误码 | 含义 | 处理 |
|--------|------|------|
| `RKNN_ERR_MODEL_INVALID` | 模型不兼容 | 用 ModelLoader.convert() 重新转换 |
| `RKNN_ERR_DEVICE_UNAVAILABLE` | NPU 驱动未加载 | `sudo bash patches/npu_driver/check_npu.sh` |
| `RGA_ERR_FORMAT` | 图像格式不支持 | 确保 nv12/rgb888/bgr888 |

## 性能建议

- 推荐输入分辨率: 640×640 (YOLO 系列最优)
- 批量推理时建议 batch=4, 可达 46 FPS
- 使用 `enable_profiling=True` 定位瓶颈
