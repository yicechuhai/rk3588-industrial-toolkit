# RK3588 OpenLab API 总览

## API 架构

```
┌─────────────────────────────────────────────┐
│                应用层 / 用户代码               │
├─────────────────────────────────────────────┤
│  推理引擎 API    │  协议 API    │  OS兼容 API  │
│  (inference)    │  (protocol) │ (os-compat)  │
├─────────────────────────────────────────────┤
│          C++ 核心 (libengine.so)             │
│         NPU Driver / RGA / DMA-BUF          │
└─────────────────────────────────────────────┘
```

## API 分类

| API 类别 | 语言 | 用途 | 文档 |
|----------|------|------|------|
| 推理引擎 API | Python (pybind11) / C++ | NPU 推理、预处理、后处理 | [inference-api.md](inference-api.md) |
| 工业协议 API | Python / C | Modbus, OPC UA, EtherCAT | [protocol-api.md](protocol-api.md) |
| OS 兼容层 API | Python / Shell | 国产OS适配、NeoCertify | [os-compat-api.md](os-compat-api.md) |

## 核心设计原则

1. **零拷贝 (Zero-Copy)**: DMA-BUF 共享内存，Frame → NPU 无需拷贝
2. **上下文管理器**: 所有资源类实现 `__enter__` / `__exit__`
3. **NumPy 原生**: 输入输出直接使用 `numpy.ndarray`，无需序列化
4. **工厂模式**: `ModelLoader` 自动识别 ONNX/PyTorch/RKNN 格式
5. **服务化**: Modbus/OPC UA 以 systemd 守护进程方式运行

## 快速使用

```python
from rk3588_engine import Engine
from rk3588_protocol import ModbusServer

# 推理
with Engine("yolov5s.rknn") as eng:
    results = eng.infer(frame)  # frame: np.ndarray (H,W,3)

# 协议
server = ModbusServer(config="modbus.yaml")
server.start()
```

## 性能约定

- 所有 API 调用默认**非阻塞**（异步 I/O）
- NPU 推理返回 `Stats` 对象，含延迟/吞吐量
- 协议 API 支持多客户端并发连接
