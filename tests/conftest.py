# conftest.py — pytest 共享 fixtures
# RK3588 Industrial Toolkit Test Suite

import pytest
import os
import sys

# 将项目根目录和 engine python 加入路径
REPO_ROOT = os.path.dirname(os.path.abspath(__file__))
ENGINE_PYTHON = os.path.join(REPO_ROOT, "..", "deploy", "engine", "python")
sys.path.insert(0, ENGINE_PYTHON)


@pytest.fixture
def sample_detection():
    """返回一个模拟 Detection 结果"""
    return {
        "class_id": 0,
        "class_name": "person",
        "confidence": 0.95,
        "bbox": [100.0, 150.0, 200.0, 300.0],
    }


@pytest.fixture
def sample_detections():
    """返回多个模拟 Detection 结果"""
    return [
        {"class_id": 0, "class_name": "person", "confidence": 0.95, "bbox": [100, 150, 200, 300]},
        {"class_id": 2, "class_name": "car", "confidence": 0.87, "bbox": [300, 200, 180, 220]},
        {"class_id": 5, "class_name": "bus", "confidence": 0.72, "bbox": [50, 80, 250, 180]},
    ]


@pytest.fixture
def sample_system_status():
    """返回模拟系统状态"""
    return {
        "cpu_usage": 45.2,
        "memory_usage": 62.1,
        "npu_temperature": 58.3,
        "inference_fps": 54.0,
    }


@pytest.fixture
def engine_config():
    """返回引擎配置字典"""
    return {
        "model": {
            "path": "./models/yolov5s.rknn",
            "input_size": [640, 640],
            "num_classes": 80,
            "conf_threshold": 0.5,
            "nms_threshold": 0.45,
        },
        "npu": {"core_mask": 0x7},  # 3 核心
        "preprocess": {
            "mean": [0, 0, 0],
            "std": [255, 255, 255],
            "letterbox": True,
        },
    }