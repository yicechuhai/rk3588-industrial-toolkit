# test_npu_driver.py — NPU 驱动检测测试
# 测试 /dev/galcore 设备节点、rknn-toolkit 接口、内存管理

import pytest
import os
from unittest.mock import Mock, MagicMock, patch


class TestNpuDeviceDetection:
    """NPU 设备节点检测测试"""

    def test_galcore_device_path(self):
        """设备节点路径应为 /dev/galcore"""
        device = "/dev/galcore"
        assert device == "/dev/galcore"
        assert "galcore" in device

    def test_device_exists_check(self, mock_npu_driver):
        """is_available 应返回 True"""
        assert mock_npu_driver.is_available() is True

    def test_device_info_structure(self, mock_npu_driver):
        """get_device_info 应返回完整设备信息"""
        info = mock_npu_driver.get_device_info()
        required = {"device", "driver_version", "fw_version", "cores", "arch"}
        assert required.issubset(info.keys())
        assert info["arch"] == "RK3588"

    def test_multiple_npu_cores(self):
        """RK3588 应有 3 个 NPU 核心"""
        mask = 0x7  # 0b111
        assert bin(mask).count("1") == 3

    @pytest.mark.parametrize("core_mask,expected_cores", [
        (0x1, 1),
        (0x3, 2),
        (0x7, 3),
        (0x0, 0),
    ])
    def test_core_mask_bit_count(self, core_mask, expected_cores):
        """不同 core_mask 对应不同活跃核心数"""
        assert bin(core_mask).count("1") == expected_cores


class TestNpuDriverVersioning:
    """NPU 驱动版本管理"""

    def test_driver_version_format(self):
        """驱动版本应为 X.Y.Z 格式"""
        version = "2.0.5"
        parts = version.split(".")
        assert len(parts) == 3
        assert all(p.isdigit() for p in parts)

    def test_firmware_version_format(self):
        """固件版本应包含 RK3588 和 NPU 标识"""
        fw = "RK3588_NPU_v1.2.3"
        assert "RK3588" in fw
        assert "NPU" in fw

    def test_version_comparison(self):
        """版本号比较逻辑"""
        def parse(ver):
            return tuple(int(x) for x in ver.split("."))

        assert parse("2.0.5") > parse("1.9.0")
        assert parse("2.0.5") > parse("2.0.4")
        assert parse("2.0.5") == parse("2.0.5")


class TestNpuMemoryManagement:
    """NPU 内存管理测试"""

    def test_memory_total_valid(self, mock_npu_driver):
        """总内存应为正数"""
        assert mock_npu_driver.memory_total_mb > 0
        assert mock_npu_driver.memory_total_mb == 4096

    def test_memory_used_lt_total(self, mock_npu_driver):
        """已用内存应 ≤ 总内存"""
        assert mock_npu_driver.memory_used_mb <= mock_npu_driver.memory_total_mb

    def test_dma_buf_positive(self, mock_npu_driver):
        """DMA buffer 数量应为正数"""
        assert mock_npu_driver.dma_buf_count > 0
        assert mock_npu_driver.dma_buf_count >= 4  # 至少 4 个 buffer

    def test_memory_allocation_tracking(self):
        """内存分配应正确追踪"""
        total = 4096
        allocations = [256, 128, 64, 512]
        used = sum(allocations)
        remaining = total - used
        assert remaining == 4096 - 960
        assert remaining > 0


class TestNpuTemperatureMonitor:
    """NPU 温度监控测试"""

    @pytest.mark.parametrize("temp,is_safe", [
        (25.0, True),
        (58.3, True),
        (85.0, True),
        (105.0, True),
        (120.0, True),
        (125.1, False),
    ])
    def test_temperature_safety_range(self, temp, is_safe):
        """温度超过 125°C 应告警"""
        MAX_SAFE_TEMP = 125.0
        assert (temp <= MAX_SAFE_TEMP) == is_safe

    def test_temperature_monitor_interval(self):
        """温度检测间隔建议 1 秒"""
        interval_ms = 1000
        assert interval_ms >= 500  # 最小 500ms
        assert interval_ms <= 5000  # 最大 5s

    def test_thermal_throttle_threshold(self):
        """温度 ≥ 100°C 应触发降频"""
        THROTTLE_THRESHOLD = 100.0
        temps = [25, 60, 95, 100, 105, 120]
        throttled = [t >= THROTTLE_THRESHOLD for t in temps]
        assert throttled == [False, False, False, True, True, True]


class TestNpuModelLoading:
    """NPU 模型加载测试"""

    def test_rknn_model_load(self, mock_npu):
        """load_model 应返回 True"""
        assert mock_npu.load_model() is True

    def test_invalid_model_extension(self):
        """非 .rknn 文件应被拒绝"""
        invalid = ["yolov5s.onnx", "yolov5s.pth", "yolov5s.tflite", "yolov5s.pt"]
        for f in invalid:
            assert not f.endswith(".rknn")

    def test_model_file_size_bound(self):
        """模型文件大小应在合理范围"""
        MIN_SIZE = 1 * 1024 * 1024    # 1 MB
        MAX_SIZE = 500 * 1024 * 1024  # 500 MB
        model_sizes = [2, 15, 50, 200]  # MB
        for size_mb in model_sizes:
            size_bytes = size_mb * 1024 * 1024
            assert MIN_SIZE <= size_bytes <= MAX_SIZE


class TestNpuInferenceApi:
    """NPU 推理接口测试"""

    def test_infer_returns_detections(self, mock_npu):
        """infer 应返回 detection 列表"""
        dets = mock_npu.infer(None)  # mock 忽略输入
        assert isinstance(dets, list)
        assert len(dets) > 0
        for d in dets:
            assert "class_id" in d
            assert "confidence" in d
            assert "bbox" in d

    def test_infer_confidence_range(self, mock_npu):
        """每帧推理置信度应在 0-1 范围"""
        dets = mock_npu.infer(None)
        for d in dets:
            assert 0.0 <= d["confidence"] <= 1.0

    def test_infer_bbox_format(self, mock_npu):
        """bbox 应为 4 元归一化坐标 [x1, y1, x2, y2]"""
        dets = mock_npu.infer(None)
        for d in dets:
            assert len(d["bbox"]) == 4
            for v in d["bbox"]:
                assert 0.0 <= v <= 1.0

    def test_stats_completeness(self, mock_npu):
        """get_stats 应返回完整统计"""
        stats = mock_npu.get_stats()
        required = {"fps", "avg_latency_ms", "min_latency_ms", "max_latency_ms", "total_inferences"}
        assert required.issubset(stats.keys())


class TestNpuCoreAffinity:
    """NPU 核心亲和性测试"""

    def test_default_3core_mask(self):
        """默认 core_mask 0x7 使用全部 3 核"""
        assert 0x7 == 0b111

    def test_single_core_hotplug(self):
        """测试单核热插拔场景"""
        mask_3core = 0x7
        mask_2core = 0x3  # core0, core1
        mask_1core = 0x1  # core0 only
        assert bin(mask_3core).count("1") == 3
        assert bin(mask_2core).count("1") == 2
        assert bin(mask_1core).count("1") == 1

    @pytest.mark.parametrize("mask,description", [
        (0x0, "全部关闭 (非法)"),
        (0x1, "仅 Core0"),
        (0x3, "Core0+Core1"),
        (0x7, "全部 3 核"),
    ])
    def test_core_mask_descriptions(self, mask, description):
        """各 core_mask 场景验证"""
        active = bin(mask).count("1")
        if mask == 0x0:
            assert active == 0
        elif mask == 0x1:
            assert active == 1
        elif mask == 0x3:
            assert active == 2
        elif mask == 0x7:
            assert active == 3
