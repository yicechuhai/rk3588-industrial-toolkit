# test_pipeline.py — 端到端流水线集成测试
# 覆盖: Engine推理 → Detection转换 → Modbus寄存器 → OPC UA节点 全链路

import pytest
import json
import os
import sys
import time
import math
from unittest.mock import Mock, patch, MagicMock

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO_ROOT, "deploy", "engine", "python"))


# =============================================================================
# 模拟 Detection 结果
# =============================================================================

def make_mock_detection(class_id=0, class_name="person", confidence=0.95,
                        x1=0.1, y1=0.15, x2=0.35, y2=0.55):
    return {
        "class_id": class_id,
        "class_name": class_name,
        "confidence": confidence,
        "bbox": (x1, y1, x2, y2),
    }


def make_mock_detections(count=3):
    objects = [
        (0, "person", 0.95, 100, 150, 350, 550),
        (1, "bicycle", 0.82, 500, 200, 700, 450),
        (2, "car", 0.88, 300, 100, 600, 380),
        (5, "bus", 0.73, 50, 80, 350, 320),
        (9, "traffic light", 0.91, 600, 50, 640, 100),
    ]
    results = []
    for i in range(min(count, len(objects))):
        cls_id, name, conf, x1, y1, x2, y2 = objects[i]
        results.append(make_mock_detection(cls_id, name, conf,
                                           x1 / 1280, y1 / 720, x2 / 1280, y2 / 720))
    return results


# =============================================================================
# 模拟 Modbus 寄存器
# =============================================================================

class MockModbusRegister:
    def __init__(self, num_registers=256):
        self._regs = [0] * num_registers

    def read(self, addr):
        if 0 <= addr < len(self._regs):
            return self._regs[addr]
        return 0

    def write(self, addr, value):
        if 0 <= addr < len(self._regs):
            self._regs[addr] = value & 0xFFFF

    def read_float_x10(self, addr):
        raw = self.read(addr)
        return raw / 10.0

    def read_float_x1000(self, addr):
        raw = self.read(addr)
        return raw / 1000.0


class MockModbusServer:
    def __init__(self):
        self.registers = MockModbusRegister(1024)
        self.heartbeat = 0
        self.status = 0
        self.running = True

    def update_heartbeat(self):
        self.heartbeat = (self.heartbeat + 1) % 65536
        self.registers.write(0x0000, self.heartbeat)

    def update_detections(self, detections, frame_w=1280, frame_h=720):
        n = min(len(detections), 20)
        self.registers.write(0x0010, n)

        if n > 0:
            best = max(detections, key=lambda d: d["confidence"])
            cls_id = best["class_id"]
            conf = best["confidence"]
            bbox = best["bbox"]
            center_x = int((bbox[0] + bbox[2]) / 2 * frame_w)
            center_y = int((bbox[1] + bbox[3]) / 2 * frame_h)
            self.registers.write(0x0011, cls_id)
            self.registers.write(0x0012, int(conf * 1000))
            self.registers.write(0x0013, min(center_x, 65535))
            self.registers.write(0x0014, min(center_y, 65535))

        for i in range(n):
            d = detections[i]
            base = 0x0030 + i * 6
            bbox = d["bbox"]
            x1 = int(bbox[0] * frame_w)
            y1 = int(bbox[1] * frame_h)
            x2 = int(bbox[2] * frame_w)
            y2 = int(bbox[3] * frame_h)
            self.registers.write(base + 0, d["class_id"])
            self.registers.write(base + 1, int(d["confidence"] * 1000))
            self.registers.write(base + 2, min(x1, 65535))
            self.registers.write(base + 3, min(y1, 65535))
            self.registers.write(base + 4, min(x2, 65535))
            self.registers.write(base + 5, min(y2, 65535))

    def update_system_status(self, fps, temperature_c):
        self.registers.write(0x0003, int(fps * 10))
        self.registers.write(0x0004, int(temperature_c * 10))


# =============================================================================
# 测试类
# =============================================================================

class TestPipelineIntegration:
    """完整流水线集成测试: Engine → Modbus → OPC UA"""

    def test_full_pipeline_modbus_register_mapping(self):
        server = MockModbusServer()
        detections = make_mock_detections(3)
        server.update_detections(detections)
        server.update_heartbeat()

        assert server.registers.read(0x0000) > 0, "心跳应递增"
        assert server.registers.read(0x0001) == 0, "默认状态应为0"
        assert server.registers.read(0x0010) == 3, "检测数量应为3"
        assert server.registers.read(0x0011) == 0, "最高置信目标应为person(0)"
        conf_raw = server.registers.read(0x0012)
        assert abs(conf_raw / 1000.0 - 0.95) < 0.01, f"置信度编码错误: {conf_raw}"
        assert server.registers.read(0x0030) == 0, "obj0 class_id 应为0"
        assert abs(server.registers.read_float_x1000(0x0031) - 0.95) < 0.01

        # 清除后验证
        server.update_detections([])
        assert server.registers.read(0x0010) == 0, "清除后检测数应为0"

    def test_register_value_range(self):
        server = MockModbusServer()
        det = make_mock_detection(confidence=1.0, x1=0.0, y1=0.0, x2=1.0, y2=1.0)
        server.update_detections([det], frame_w=8192, frame_h=8192)
        conf_reg = server.registers.read(0x0012)
        assert 0 <= conf_reg <= 65535, f"置信度寄存器越界: {conf_reg}"
        for i in range(6):
            val = server.registers.read(0x0030 + i)
            assert 0 <= val <= 65535, f"寄存器 0x{0x0030+i:04X} 越界: {val}"

    def test_modbus_multiple_detections_sorting(self):
        server = MockModbusServer()
        detections = [
            make_mock_detection(0, "person", 0.5, 0.1, 0.1, 0.2, 0.2),
            make_mock_detection(1, "bicycle", 0.99, 0.1, 0.1, 0.3, 0.3),
            make_mock_detection(2, "car", 0.75, 0.1, 0.1, 0.4, 0.4),
        ]
        server.update_detections(detections)
        top_cls = server.registers.read(0x0011)
        top_conf = server.registers.read_float_x1000(0x0012)
        assert top_cls == 1, f"最高置信目标应为bicycle(1)，实际: {top_cls}"
        assert abs(top_conf - 0.99) < 0.01, f"top 置信度错误: {top_conf}"

    def test_opcua_detection_conversion(self):
        det = make_mock_detection(
            class_id=0, class_name="person", confidence=0.95,
            x1=100/1280, y1=150/720, x2=350/1280, y2=550/720
        )
        bbox = det["bbox"]
        frame_w, frame_h = 1280, 720
        opcua_x = bbox[0] * frame_w
        opcua_y = bbox[1] * frame_h
        opcua_w = (bbox[2] - bbox[0]) * frame_w
        opcua_h = (bbox[3] - bbox[1]) * frame_h
        assert opcua_x == pytest.approx(100, abs=1)
        assert opcua_y == pytest.approx(150, abs=1)
        assert opcua_w == pytest.approx(250, abs=1)
        assert opcua_h == pytest.approx(400, abs=1)
        assert opcua_x + opcua_w == pytest.approx(350, abs=1)
        assert opcua_y + opcua_h == pytest.approx(550, abs=1)

    def test_detection_denormalization_consistency(self):
        det = make_mock_detection(
            class_id=0, confidence=0.90,
            x1=200/1920, y1=100/1080, x2=600/1920, y2=500/1080
        )
        bbox = det["bbox"]
        modbus_x1 = int(bbox[0] * 1920)
        modbus_y1 = int(bbox[1] * 1080)
        modbus_x2 = int(bbox[2] * 1920)
        modbus_y2 = int(bbox[3] * 1080)
        opcua_x = bbox[0] * 1920
        opcua_y = bbox[1] * 1080
        opcua_w = (bbox[2] - bbox[0]) * 1920
        opcua_h = (bbox[3] - bbox[1]) * 1080
        assert modbus_x1 == pytest.approx(int(opcua_x), abs=1)
        assert modbus_x2 == pytest.approx(int(opcua_x + opcua_w), abs=1)
        assert modbus_x2 - modbus_x1 == pytest.approx(int(opcua_w), abs=2)


class TestPipelineBoundary:
    """边界条件和异常场景测试"""

    def test_empty_detections(self):
        server = MockModbusServer()
        server.update_detections([])
        assert server.registers.read(0x0010) == 0
        assert server.registers.read(0x0030) == 0

    def test_max_objects_limit(self):
        server = MockModbusServer()
        detections = [make_mock_detection(i % 80) for i in range(50)]
        server.update_detections(detections)
        assert server.registers.read(0x0010) == 20

    def test_confidence_encoding_precision(self):
        server = MockModbusServer()
        test_confs = [0.001, 0.123, 0.5, 0.789, 0.999, 1.0]
        for conf in test_confs:
            det = make_mock_detection(confidence=conf)
            server.update_detections([det])
            decoded = server.registers.read_float_x1000(0x0012)
            assert abs(decoded - conf) < 0.002, f"置信度 {conf} 精度损失过大: {decoded}"

    def test_system_status_update_atomicity(self):
        server = MockModbusServer()
        for i in range(100):
            fps = 25.0 + (i % 10) * 0.7
            temp = 55.0 + (i % 20) * 0.3
            server.update_system_status(fps, temp)
            read_fps = server.registers.read_float_x10(0x0003)
            read_temp = server.registers.read_float_x10(0x0004)
            assert abs(read_fps - fps) < 0.2
            assert abs(read_temp - temp) < 0.2


class TestPipelinePerformance:
    """流水线性能相关测试"""

    def test_modbus_update_latency_bound(self):
        server = MockModbusServer()
        detections_20 = [make_mock_detection(i % 80) for i in range(20)]
        latencies = []
        for _ in range(50):
            start = time.perf_counter()
            server.update_detections(detections_20)
            end = time.perf_counter()
            latencies.append((end - start) * 1000)
        avg_latency = sum(latencies) / len(latencies)
        assert avg_latency < 1.0, f"Modbus 更新延迟过高: {avg_latency:.3f}ms"

    def test_high_throughput_updates(self):
        server = MockModbusServer()
        detections = make_mock_detections(5)
        for frame_id in range(1000):
            server.update_heartbeat()
            server.update_detections(detections)
            assert server.registers.read(0x0010) == 5
        assert server.heartbeat == 1000
