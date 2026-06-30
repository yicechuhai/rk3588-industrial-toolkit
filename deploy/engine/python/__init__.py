"""
rknn-engine -- Python bindings for the RK3588 zero-copy NPU inference engine.

提供面向 Python 用户的高级 API 和底层 C++ 绑定。

典型用法:

    from rknn_engine import Engine          # C++ pybind11 绑定
    from rknn_engine import RK3588Engine    # Pythonic 封装

    # 推荐: 使用 Pythonic API
    with RK3588Engine("config/engine.yaml") as eng:
        eng.load_model("models/yolov5s.rknn")
        detections = eng.infer(frame_np)
        print(eng.get_stats())

    # 或者: 直接使用 C++ 绑定
    from rknn_engine import Engine
    eng = Engine("config/engine.yaml")
    eng.load_model("models/yolov5s.rknn")
    results = eng.infer(frame_np, format="BGR888")
"""

from rknn_engine import Engine           # noqa: F401   C++ pybind11 绑定
from rknn_engine.engine import (         # noqa: F401   Pythonic API
    RK3588Engine,
    create_engine,
    RK3588EngineError,
    EngineInitError,
    ModelLoadError,
    InferenceError,
    InvalidInputError,
    EngineNotReadyError,
)

__all__ = [
    # C++ 绑定
    "Engine",
    # Pythonic API
    "RK3588Engine",
    "create_engine",
    # 异常
    "RK3588EngineError",
    "EngineInitError",
    "ModelLoadError",
    "InferenceError",
    "InvalidInputError",
    "EngineNotReadyError",
]

__version__ = "1.1.0"
