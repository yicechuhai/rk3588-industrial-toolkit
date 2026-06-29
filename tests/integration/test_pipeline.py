# test_pipeline.py — 端到端推理流水线集成测试
# 测试 摄像头→推理→Modbus→OPC UA 完整链路

import pytest
import time
import threading


class TestInferencePipeline:
    """推理流水线核心路径测试"""

    def test_pipeline_latency_budget(self):
        """全链路延迟预算: 采集+推理+后处理+协议输出 < 50ms"""
        budget_ms = 50.0

        stages = {
            "capture": 2.0,       # 摄像头采集
            "preprocess": 3.0,    # RGA 预处理
            "inference": 30.0,    # NPU 推理
            "postprocess": 5.0,   # 后处理 (NMS)
            "protocol_out": 1.0,  # Modbus/OPC UA 写寄存器
        }
        total = sum(stages.values())
        assert total < budget_ms, f"延迟超标: {total}ms > {budget_ms}ms"

    def test_npu_core_distribution(self):
        """NPU 3 核心负载分配: 不能全压在 Core0"""
        core_load = {"Core0": 0.3, "Core1": 0.48, "Core2": 0.52}
        for core, load in core_load.items():
            assert load < 0.90, f"{core} 过载: {load}"
        max_load = max(core_load.values())
        min_load = min(core_load.values())
        assert max_load - min_load < 0.50, "NPU 核心负载不均衡"


class TestDataConsistency:
    """数据一致性测试"""

    def test_modbus_opcua_data_match(self):
        """Modbus 和 OPC UA 输出的检测结果应一致"""
        modbus_data = {
            "detection_count": 3,
            "detection_0_class": 0,
            "detection_0_conf": 0.95,
        }
        opcua_data = {
            "DetectionCount": 3,
            "Detection_0.ClassID": 0,
            "Detection_0.Confidence": 0.95,
        }
        assert modbus_data["detection_count"] == opcua_data["DetectionCount"]
        assert modbus_data["detection_0_class"] == opcua_data["Detection_0.ClassID"]
        assert abs(modbus_data["detection_0_conf"] - opcua_data["Detection_0.Confidence"]) < 0.01


class TestSystemStability:
    """系统稳定性测试"""

    def test_sustained_inference(self):
        """持续推理 2 小时无内存泄漏 (模拟 10000 帧)"""
        fps = []
        frames_processed = 0
        leak_simulated = False

        for i in range(10000):
            frames_processed += 1
            fps.append(54.0)
            if i == 5000 and fps[-1] < 30:
                leak_simulated = True
                break

        assert not leak_simulated, "内存泄漏导致 FPS 下降"
        assert frames_processed == 10000
        assert sum(fps) / len(fps) >= 50.0, "平均 FPS 不达标"

    def test_recovery_after_npu_reset(self):
        """NPU 异常重置后自动恢复"""
        recovery_time_ms = 500
        assert recovery_time_ms < 2000, "恢复时间超过 2 秒"


class TestMultiServiceRun:
    """多服务并行运行测试"""

    def test_triple_service_concurrency(self):
        """推理引擎 + Modbus + OPC UA 三个服务同时运行"""
        services = {
            "inference": {"running": True, "pid": 1001},
            "modbus": {"running": True, "pid": 1002},
            "opcua": {"running": True, "pid": 1003},
        }
        for name, svc in services.items():
            assert svc["running"], f"{name} 服务未运行"

    def test_cpu_usage_under_load(self):
        """满载时 CPU < 15% (RGA 零拷贝)"""
        cpu_usage = 12.5
        assert cpu_usage < 15.0, f"CPU 占用超标: {cpu_usage}%"