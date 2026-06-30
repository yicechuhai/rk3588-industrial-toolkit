# benchmark/conftest.py — 基准测试共享 fixtures

import pytest
import time
import numpy as np
from unittest.mock import MagicMock


@pytest.fixture
def benchmark_config():
    """基准测试配置参数"""
    return {
        "warmup_iterations": 50,
        "benchmark_iterations": 500,
        "min_fps_threshold": 30.0,
        "max_latency_ms": 50.0,
        "model_path": "./models/yolov5s.rknn",
        "input_size": [640, 640],
        "npu_cores": 3,
        "batch_sizes": [1, 2, 4, 8],
    }


@pytest.fixture
def mock_npu_bench():
    """用于基准测试的 NPU 模拟 (可调延迟)"""
    npu = MagicMock()
    npu.core_count = 3
    npu.core_mask = 0x7

    # 模拟推理延迟：可配置
    npu.inference_latency_ms = 18.5

    def infer(input_tensor):
        # 模拟 NPU 计算延迟
        time.sleep(npu.inference_latency_ms / 1000.0)
        return [
            {"class_id": 0, "confidence": 0.95, "bbox": [0.1, 0.15, 0.35, 0.55]},
        ]

    npu.infer = infer
    return npu


@pytest.fixture
def generate_benchmark_frames():
    """生成基准测试帧 (批量)"""
    def _generate(batch_size, width=640, height=640):
        return np.random.randint(0, 256, (batch_size, height, width, 3), dtype=np.uint8)
    return _generate


@pytest.fixture
def latency_recorder():
    """延迟记录器"""
    class Recorder:
        def __init__(self):
            self.records = []

        def record(self, latency_ms):
            self.records.append(latency_ms)

        def stats(self):
            if not self.records:
                return {}
            arr = np.array(self.records)
            return {
                "count": len(arr),
                "avg": float(np.mean(arr)),
                "min": float(np.min(arr)),
                "max": float(np.max(arr)),
                "p50": float(np.percentile(arr, 50)),
                "p95": float(np.percentile(arr, 95)),
                "p99": float(np.percentile(arr, 99)),
                "std": float(np.std(arr)),
            }

        def clear(self):
            self.records = []

    return Recorder()


@pytest.fixture
def fps_calculator():
    """FPS 计算器"""
    class Calculator:
        def __init__(self):
            self.frame_times = []

        def tick(self):
            self.frame_times.append(time.perf_counter())

        def fps(self):
            if len(self.frame_times) < 2:
                return 0.0
            elapsed = self.frame_times[-1] - self.frame_times[0]
            return (len(self.frame_times) - 1) / elapsed if elapsed > 0 else 0.0

        def clear(self):
            self.frame_times = []

    return Calculator()
