# conftest.py — pytest 共享 fixtures
# RK3588 Industrial Toolkit Test Suite

import pytest
import os
import sys
import numpy as np
from unittest.mock import Mock, MagicMock, patch

# 将项目根目录和 engine python 加入路径
REPO_ROOT = os.path.dirname(os.path.abspath(__file__))
ENGINE_PYTHON = os.path.join(REPO_ROOT, "..", "deploy", "engine", "python")
sys.path.insert(0, ENGINE_PYTHON)


# =====================================================================
# 基础数据 fixtures
# =====================================================================

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


# =====================================================================
# NPU 模拟 fixtures
# =====================================================================

@pytest.fixture
def mock_npu():
    """模拟 NPU 设备：含 rknn 初始化、推理、性能统计"""
    npu = MagicMock()
    npu.device_id = 0
    npu.core_count = 3
    npu.core_mask = 0x7
    npu.model_path = "./models/yolov5s.rknn"
    npu.is_initialized = True
    npu.temperature_c = 58.3
    npu.clock_freq_mhz = 850

    # 模拟推理返回
    npu.infer.return_value = [
        {"class_id": 0, "confidence": 0.95, "bbox": [0.1, 0.15, 0.35, 0.55]},
        {"class_id": 2, "confidence": 0.87, "bbox": [0.3, 0.2, 0.5, 0.45]},
    ]
    npu.get_stats.return_value = {
        "fps": 54.0,
        "avg_latency_ms": 18.5,
        "min_latency_ms": 14.2,
        "max_latency_ms": 25.1,
        "total_inferences": 1000,
    }
    npu.load_model.return_value = True
    return npu


@pytest.fixture
def mock_npu_driver():
    """模拟 NPU 驱动层：设备节点、DMA、内存管理"""
    driver = MagicMock()
    driver.device_path = "/dev/galcore"
    driver.version = "2.0.5"
    driver.firmware_version = "RK3588_NPU_v1.2.3"
    driver.dma_buf_count = 8
    driver.memory_total_mb = 4096
    driver.memory_used_mb = 512
    driver.is_available.return_value = True
    driver.get_device_info.return_value = {
        "device": "/dev/galcore",
        "driver_version": "2.0.5",
        "fw_version": "RK3588_NPU_v1.2.3",
        "cores": 3,
        "arch": "RK3588",
    }
    return driver


# =====================================================================
# 摄像头模拟 fixtures
# =====================================================================

@pytest.fixture
def mock_camera():
    """模拟摄像头采集：RTSP 流、帧读取、分辨率控制"""
    cam = MagicMock()
    cam.source_url = "rtsp://192.168.1.100:554/stream1"
    cam.resolution = (1920, 1080)
    cam.fps = 30
    cam.is_connected = True
    cam.frame_count = 0

    # 模拟帧读取：返回 (640, 640, 3) 的 RGB 图像
    cam.read_frame.return_value = np.random.randint(0, 256, (640, 640, 3), dtype=np.uint8)
    cam.get_resolution.return_value = (1920, 1080)
    cam.get_fps.return_value = 30.0
    cam.reconnect.return_value = True
    return cam


@pytest.fixture
def mock_camera_raw():
    """模拟摄像头原生采集：V4L2/MIPI 接口"""
    cam = MagicMock()
    cam.device_path = "/dev/video0"
    cam.driver = "rkisp"
    cam.format = "NV12"
    cam.resolution = (1920, 1080)
    cam.fps = 30
    cam.buffer_count = 4
    cam.is_streaming = True

    cam.read_raw_frame.return_value = np.zeros((1080, 1920, 2), dtype=np.uint8)
    cam.set_format.return_value = True
    cam.start_streaming.return_value = True
    cam.stop_streaming.return_value = True
    return cam


# =====================================================================
# RTSP 流模拟 fixtures
# =====================================================================

@pytest.fixture
def mock_rtsp():
    """模拟 RTSP 流管理：连接、重连、多路流"""
    rtsp = MagicMock()
    rtsp.url = "rtsp://192.168.1.100:554/stream1"
    rtsp.transport = "tcp"
    rtsp.timeout_sec = 10
    rtsp.reconnect_interval_sec = 3
    rtsp.max_reconnects = 5
    rtsp.is_connected = True
    rtsp.reconnect_count = 0
    rtsp.bytes_received = 0
    rtsp.frames_decoded = 0

    rtsp.connect.return_value = True
    rtsp.disconnect.return_value = True
    rtsp.read_packet.return_value = b"RTSP_PACKET_DATA"
    rtsp.get_sdp.return_value = {
        "streams": [{"type": "video", "codec": "H264", "pt": 96}],
        "control": "rtsp://192.168.1.100:554/stream1/",
    }
    return rtsp


@pytest.fixture
def mock_rtsp_pipeline():
    """模拟 RTSP → 解码 → NPU 推理 管道"""
    pipeline = MagicMock()
    pipeline.name = "rtsp_npu_pipeline"
    pipeline.input_url = "rtsp://192.168.1.100:554/stream1"
    pipeline.model_path = "./models/yolov5s.rknn"
    pipeline.frame_width = 640
    pipeline.frame_height = 640
    pipeline.fps = 30
    pipeline.is_running = True
    pipeline.total_frames = 0
    pipeline.total_detections = 0

    pipeline.process_frame.return_value = [
        {"class_id": 0, "confidence": 0.95, "bbox": [0.1, 0.15, 0.35, 0.55]},
    ]
    pipeline.get_pipeline_stats.return_value = {
        "input_fps": 30.0,
        "decode_fps": 29.8,
        "inference_fps": 54.0,
        "output_fps": 30.0,
        "latency_total_ms": 52.3,
    }
    pipeline.start.return_value = True
    pipeline.stop.return_value = True
    return pipeline


# =====================================================================
# 协议栈模拟 fixtures
# =====================================================================

@pytest.fixture
def mock_modbus_server():
    """模拟 Modbus TCP 服务器"""
    server = MagicMock()
    server.host = "0.0.0.0"
    server.port = 502
    server.slave_id = 1
    server.is_running = True
    server.client_count = 0
    server.max_clients = 8

    server.read_holding_register.return_value = 12345
    server.read_input_register.return_value = 6789
    server.write_register.return_value = True
    server.start.return_value = True
    server.stop.return_value = True
    return server


@pytest.fixture
def mock_opcua_server():
    """模拟 OPC UA 服务器"""
    server = MagicMock()
    server.endpoint = "opc.tcp://0.0.0.0:4840"
    server.server_name = "RK3588_Industrial"
    server.is_running = True
    server.namespace_index = 2

    server.get_node.return_value = {
        "node_id": "ns=2;s=CPU_Usage",
        "value": 45.2,
        "type": "Double",
    }
    server.set_node_value.return_value = True
    server.start.return_value = True
    server.stop.return_value = True
    return server


# =====================================================================
# 测试数据生成器
# =====================================================================

@pytest.fixture
def generate_test_frame():
    """生成指定分辨率的随机测试帧（numpy 数组）"""
    def _generate(width=640, height=640, channels=3):
        return np.random.randint(0, 256, (height, width, channels), dtype=np.uint8)
    return _generate


@pytest.fixture
def generate_detections():
    """批量生成指定数量的模拟 Detection"""
    def _generate(count=5, frame_w=1280, frame_h=720):
        classes = ["person", "bicycle", "car", "motorcycle", "bus", "truck",
                    "traffic light", "stop sign", "cat", "dog"]
        detections = []
        for i in range(count):
            cls_id = i % len(classes)
            conf = 0.5 + (i * 0.05) % 0.5
            x1 = (i * 50) % frame_w
            y1 = (i * 30) % frame_h
            x2 = min(x1 + 200, frame_w)
            y2 = min(y1 + 300, frame_h)
            detections.append({
                "class_id": cls_id,
                "class_name": classes[cls_id],
                "confidence": round(conf, 3),
                "bbox": [x1, y1, x2, y2],
            })
        return detections
    return _generate


@pytest.fixture
def generate_system_metrics():
    """生成系统指标快照"""
    def _generate(cpu=45.0, mem=62.0, temp=58.0, fps=54.0):
        return {
            "timestamp": 1700000000.0,
            "cpu_usage": cpu,
            "memory_usage": mem,
            "npu_temperature": temp,
            "inference_fps": fps,
            "uptime_seconds": 3600,
        }
    return _generate


@pytest.fixture
def benchmark_config():
    """基准测试配置"""
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
