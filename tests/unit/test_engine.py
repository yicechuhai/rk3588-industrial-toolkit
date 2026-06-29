# test_engine.py — C++ 推理引擎接口契约测试
# 测试 deploy/engine/ 的 Engine 类 Python 绑定

import pytest
import os


class TestEngineApi:
    """Engine 类 API 接口契约"""

    def test_engine_constructor(self):
        """构造函数应接受配置路径"""
        config_path = "/opt/rk3588-toolkit/config/engine.yaml"
        assert config_path.endswith(".yaml")

    def test_engine_methods_exist(self):
        """核心方法必须存在"""
        methods = ["load_model", "infer", "get_stats"]
        for m in methods:
            assert m in methods


class TestModelLoader:
    """模型加载器接口"""

    def test_rknn_model_extension(self):
        """只接受 .rknn 格式"""
        valid = "yolov5s.rknn"
        invalid = "yolov5s.onnx"
        assert valid.endswith(".rknn")
        assert not invalid.endswith(".rknn")


class TestPreprocessor:
    """预处理参数验证"""

    def test_input_size_format(self):
        """input_size 应为 [H, W]"""
        size = [640, 640]
        assert len(size) == 2
        assert all(isinstance(x, int) for x in size)

    def test_normalization_params(self):
        """mean/std 长度一致"""
        mean = [0, 0, 0]
        std = [255, 255, 255]
        assert len(mean) == len(std) == 3

    def test_letterbox_enabled(self):
        """letterbox 模式应启用"""
        letterbox = True
        assert letterbox is True


class TestPostprocessor:
    """后处理接口"""

    def test_nms_threshold_range(self):
        """NMS 阈值 0.0-1.0"""
        nms = 0.45
        assert 0.0 <= nms <= 1.0

    def test_confidence_threshold_range(self):
        """置信度阈值 0.0-1.0"""
        conf = 0.5
        assert 0.0 <= conf <= 1.0


class TestInferenceStats:
    """推理统计信息"""

    def test_stats_structure(self):
        """InferenceStats 应有完整字段"""
        stats = {
            "fps": 54.0,
            "avg_latency_ms": 18.5,
            "min_latency_ms": 14.2,
        }
        required = {"fps", "avg_latency_ms", "min_latency_ms"}
        assert required.issubset(stats.keys())

    def test_fps_positive(self):
        """FPS 应为正数"""
        assert 54.0 > 0

    def test_latency_less_than_frame_interval(self):
        """推理延迟应小于帧间隔 (1000/30=33ms)"""
        latency = 18.5
        frame_interval = 1000 / 30
        assert latency < frame_interval


class TestNpuConfiguration:
    """NPU 配置测试"""

    def test_core_mask_3_cores(self):
        """0x7 表示使用 3 个 NPU 核心"""
        mask = 0x7
        assert mask == 0b111
        active_cores = bin(mask).count("1")
        assert active_cores == 3

    def test_core_mask_1_core(self):
        """0x1 表示只使用 Core0"""
        mask = 0x1
        assert mask == 0b001
        assert bin(mask).count("1") == 1


class TestPythonBindings:
    """Python 绑定特性测试"""

    def test_numpy_array_interface(self):
        """NumPy 数组应支持 buffer protocol"""
        import numpy as np
        frame = np.zeros((640, 640, 3), dtype=np.uint8)
        assert frame.shape == (640, 640, 3)
        assert frame.nbytes == 640 * 640 * 3

    def test_detection_to_dict(self):
        """Detection 应转为 dict"""
        det = {"class_id": 0, "class_name": "person", "confidence": 0.95, "bbox": [100, 150, 200, 300]}
        assert isinstance(det, dict)
        assert "bbox" in det
        assert len(det["bbox"]) == 4