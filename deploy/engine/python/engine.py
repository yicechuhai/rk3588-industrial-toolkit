# -*- coding: utf-8 -*-
"""
engine.py -- Pythonic API for RK3588 NPU inference engine.

面向 Python 用户的高级 API，对 C++ pybind11 模块做 Pythonic 封装：
  - RK3588Engine: 配置加载、模型推理、统计查询
  - 支持 context manager (with 语句)
  - Detection 结果自动转为 list[dict]

典型用法:
    from engine import RK3588Engine

    # 方式1: context manager
    with RK3588Engine("config/engine.yaml") as eng:
        eng.load_model("models/yolov5s.rknn")
        detections = eng.infer(frame_np)
        print(eng.get_stats())

    # 方式2: 手动管理
    eng = RK3588Engine("config/engine.yaml")
    eng.load_model("models/yolov5s.rknn")
    results = eng.infer(frame_np)
    stats = eng.get_stats()
    eng.close()

@author RK3588 Industrial Toolkit
@version 1.1.0
"""

import os
import sys
from typing import Any, Dict, List, Optional, Tuple
from pathlib import Path

# ── 导入 C++ 绑定 (pybind11) ──
# 优先当前目录，其次 LD_LIBRARY_PATH
if not hasattr(sys, "frozen"):
    _engine_dir = Path(__file__).parent.resolve()
    if str(_engine_dir) not in sys.path:
        sys.path.insert(0, str(_engine_dir))

try:
    from rknn_engine import Engine as _NativeEngine  # type: ignore
except ImportError as e:
    raise ImportError(
        "Cannot import rknn_engine. "
        "Build with: python setup.py build_ext --inplace. "
        f"Original error: {e}"
    )


# ─────────────────────────────────────────────────────────────────────────
# 异常体系
# ─────────────────────────────────────────────────────────────────────────

class RK3588EngineError(Exception):
    """RK3588 Engine 基础异常。"""
    pass


class EngineInitError(RK3588EngineError):
    """引擎初始化失败。"""
    pass


class ModelLoadError(RK3588EngineError):
    """模型加载失败。"""
    pass


class InferenceError(RK3588EngineError):
    """推理执行失败。"""
    pass


class InvalidInputError(RK3588EngineError):
    """输入数据格式不合法。"""
    pass


class EngineNotReadyError(RK3588EngineError):
    """引擎未就绪时尝试推理。"""
    pass


# ─────────────────────────────────────────────────────────────────────────
# RK3588Engine
# ─────────────────────────────────────────────────────────────────────────

class RK3588Engine:
    """RK3588 NPU 推理引擎 Pythonic API。

    封装 C++ pybind11 引擎，提供：
      - 类型安全的 infer() 方法
      - 自动格式兼容处理
      - 统计信息的 Python dict 访问
      - context manager 资源管理

    Attributes:
        config_path: YAML 配置文件路径。
        model_path:  当前加载的模型路径（None 表示未加载）。
    """

    # 支持的像素格式 → 通道数
    _FORMAT_CHANNELS = {
        "BGR888": 3, "RGB888": 3,
        "BGR": 3, "RGB": 3,
        "GRAY8": 1,
        "NV12": None, "NV21": None,
    }

    def __init__(self, config_path: str) -> None:
        """初始化 RK3588 推理引擎。

        Args:
            config_path: YAML 配置文件路径。

        Raises:
            EngineInitError: 配置解析或引擎初始化失败。
            FileNotFoundError: 配置文件不存在。
        """
        self.config_path = config_path
        self.model_path: Optional[str] = None

        if not os.path.isfile(config_path):
            raise FileNotFoundError(
                f"Config file not found: {config_path}"
            )

        try:
            self._engine = _NativeEngine(config_path)
        except RuntimeError as e:
            raise EngineInitError(
                f"Failed to init engine with {config_path}: {e}"
            )

    # ── Context manager ────────────────────────────────────────────────

    def __enter__(self) -> "RK3588Engine":
        """支持 with 语句。"""
        return self

    def __exit__(self, *args: Any) -> None:
        """退出 with 块时自动释放资源。"""
        self.close()

    def __del__(self) -> None:
        """析构时尝试释放 C++ 资源。"""
        try:
            if hasattr(self, "_engine"):
                del self._engine
        except Exception:
            pass

    # ── 模型加载 ───────────────────────────────────────────────────────

    def load_model(self, model_path: str) -> bool:
        """加载 RKNN 模型。

        Args:
            model_path: .rknn 模型文件路径。

        Returns:
            True 表示加载成功。

        Raises:
            FileNotFoundError: 模型文件不存在。
            ModelLoadError: 模型加载失败。
        """
        if not os.path.isfile(model_path):
            raise FileNotFoundError(
                f"Model file not found: {model_path}"
            )

        try:
            ok = self._engine.load_model(model_path)
            if ok:
                self.model_path = model_path
            return ok
        except RuntimeError as e:
            raise ModelLoadError(
                f"Failed to load model {model_path}: {e}"
            )

    # ── 推理 ───────────────────────────────────────────────────────────

    def infer(
        self,
        frame: "np.ndarray",  # type: ignore
        format: str = "BGR888",
    ) -> List[Dict[str, Any]]:
        """对单帧图像进行 NPU 推理（零拷贝）。

        Args:
            frame:  NumPy uint8 数组，shape [H,W] 或 [H,W,C]。
                    必须 C-contiguous。
            format: 像素格式。
                    支持: "BGR888", "RGB888", "NV12", "NV21", "GRAY8"。

        Returns:
            list[dict] — 每个检测结果包含:
                - class_id (int):     类别 ID
                - class_name (str):   类别名称
                - confidence (float): 置信度 0~1
                - bbox (tuple):       边界框 (x1, y1, x2, y2)

        Raises:
            EngineNotReadyError: 引擎未加载模型。
            InvalidInputError:   输入格式或维度不合法。
            InferenceError:      推理执行失败。
        """
        if not self.is_ready():
            raise EngineNotReadyError(
                "Engine not ready. Call load_model() first."
            )

        import numpy as np

        if not isinstance(frame, np.ndarray):
            raise InvalidInputError(
                f"frame must be np.ndarray, got {type(frame).__name__}"
            )

        if frame.dtype != np.uint8:
            raise InvalidInputError(
                f"frame dtype must be uint8, got {frame.dtype}"
            )

        # 确保 C-contiguous
        if not frame.flags.c_contiguous:
            frame = np.ascontiguousarray(frame)

        try:
            return self._engine.infer(frame, format)
        except RuntimeError as e:
            raise InferenceError(f"Inference failed: {e}")

    def infer_batch(
        self,
        frames: "np.ndarray",  # type: ignore
        format: str = "BGR888",
    ) -> List[List[Dict[str, Any]]]:
        """批量推理 [N,H,W,C] 输入。

        Args:
            frames: NumPy uint8 数组 [N,H,W,C], C-contiguous。
            format: 像素格式。

        Returns:
            list[list[dict]] — 每帧的检测结果。

        Raises:
            EngineNotReadyError: 引擎未就绪。
            InvalidInputError:   输入不合法。
            InferenceError:      推理失败。
        """
        if not self.is_ready():
            raise EngineNotReadyError(
                "Engine not ready. Call load_model() first."
            )

        import numpy as np

        if not isinstance(frames, np.ndarray) or frames.ndim != 4:
            raise InvalidInputError(
                "frames must be 4-D np.ndarray [N,H,W,C]"
            )

        if frames.dtype != np.uint8:
            raise InvalidInputError(
                f"frames dtype must be uint8, got {frames.dtype}"
            )

        if not frames.flags.c_contiguous:
            frames = np.ascontiguousarray(frames)

        try:
            return self._engine.infer_batch(frames, format)
        except RuntimeError as e:
            raise InferenceError(f"Batch inference failed: {e}")

    # ── 状态 & 统计 ────────────────────────────────────────────────────

    def is_ready(self) -> bool:
        """检查引擎是否已就绪（模型已加载）。

        Returns:
            True 如果引擎可以推理。
        """
        return self._engine.is_ready()

    def get_stats(self) -> Dict[str, float]:
        """获取推理性能统计。

        Returns:
            dict:
                - fps (float):              当前帧率
                - avg_latency_ms (float):    平均延迟 (ms)
                - min_latency_ms (float):    最小延迟 (ms)
                - max_latency_ms (float):    最大延迟 (ms)
                - total_frames (int):        累计帧数
                - preprocess_ms (float):     预处理耗时 (ms)
                - inference_ms (float):      NPU 推理耗时 (ms)
                - postprocess_ms (float):    后处理耗时 (ms)
        """
        return self._engine.get_stats()

    def reset_stats(self) -> None:
        """重置所有性能计数器。"""
        self._engine.reset_stats()

    # ── 资源管理 ───────────────────────────────────────────────────────

    def close(self) -> None:
        """关闭引擎，释放所有资源。"""
        try:
            if hasattr(self, "_engine"):
                del self._engine
        except Exception:
            pass

    # ── 信息 ───────────────────────────────────────────────────────────

    def __repr__(self) -> str:
        model = self.model_path or "no-model"
        return (
            f"RK3588Engine(config={self.config_path!r}, "
            f"model={model!r})"
        )

    @property
    def version(self) -> str:
        """引擎版本字符串。"""
        return getattr(
            _NativeEngine, "__version__",
            getattr(_NativeEngine, "version", "1.0.0")
        )


# ─────────────────────────────────────────────────────────────────────────
# 便捷函数
# ─────────────────────────────────────────────────────────────────────────

def create_engine(
    config_path: str = "/opt/rk3588-toolkit/config/engine.yaml",
    model_path: Optional[str] = None,
) -> RK3588Engine:
    """快速创建并配置引擎。

    Args:
        config_path: 引擎配置 YAML。
        model_path:  可选的模型路径，非 None 则自动加载。

    Returns:
        已配置的 RK3588Engine 实例。

    Raises:
        EngineInitError: 初始化失败。
    """
    eng = RK3588Engine(config_path)
    if model_path:
        eng.load_model(model_path)
    return eng


# ─────────────────────────────────────────────────────────────────────────
# 公开 API
# ─────────────────────────────────────────────────────────────────────────

__all__ = [
    "RK3588Engine",
    "create_engine",
    "RK3588EngineError",
    "EngineInitError",
    "ModelLoadError",
    "InferenceError",
    "InvalidInputError",
    "EngineNotReadyError",
]
