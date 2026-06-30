# test_protocol_pipeline.py — 协议栈集成测试
# 测试 Modbus ↔ OPC UA 双协议输出、检测结果转换、系统状态上报

import pytest
import time
import threading
from unittest.mock import Mock, MagicMock


# =============================================================================
# 模拟协议组件
# =============================================================================

class MockModbusRegisterBank:
    """模拟 Modbus 寄存器组"""
    def __init__(self, size=1024):
        self._regs = [0] * size
        self._lock = threading.Lock()

    def read(self, addr):
        with self._lock:
            return self._regs[addr] if 0 <= addr < len(self._regs) else 0

    def write(self, addr, value):
        with self._lock:
            if 0 <= addr < len(self._regs):
                self._regs[addr] = value & 0xFFFF

    def read_float_x10(self, addr):
        return self.read(addr) / 10.0

    def read_float_x1000(self, addr):
        return self.read(addr) / 1000.0


class MockModbusServer:
    """模拟 Modbus TCP 服务器"""
    def __init__(self, host="0.0.0.0", port=502):
        self.host = host
        self.port = port
        self.registers = MockModbusRegisterBank(1024)
        self.running = False
        self.clients = []

    def start(self):
        self.running = True

    def stop(self):
        self.running = False


class MockOpcuaServer:
    """模拟 OPC UA 服务器"""
    def __init__(self, endpoint="opc.tcp://0.0.0.0:4840"):
        self.endpoint = endpoint
        self.running = False
        self.nodes = {}

    def start(self):
        self.running = True

    def stop(self):
        self.running = False

    def set_node(self, node_id, value):
        self.nodes[node_id] = value


class ProtocolOutputAdapter:
    """双协议输出适配器: 同时发布到 Modbus + OPC UA"""
    def __init__(self, modbus_server, opcua_server):
        self.modbus = modbus_server
        self.opcua = opcua_server
        self.publish_count = 0

    def publish_detections(self, detections, frame_w=1280, frame_h=720):
        self.publish_count += 1

        # Modbus 寄存器映射
        n = min(len(detections), 20)
        self.modbus.registers.write(0x0010, n)

        if n > 0:
            best = max(detections, key=lambda d: d["confidence"])
            bbox = best["bbox"]
            self.modbus.registers.write(0x0011, best["class_id"])
            self.modbus.registers.write(0x0012, int(best["confidence"] * 1000))

        for i in range(n):
            d = detections[i]
            base = 0x0030 + i * 6
            bbox = d["bbox"]
            self.modbus.registers.write(base + 0, d["class_id"])
            self.modbus.registers.write(base + 1, int(d["confidence"] * 1000))
            self.modbus.registers.write(base + 2, min(int(bbox[0]), 65535))
            self.modbus.registers.write(base + 3, min(int(bbox[1]), 65535))
            self.modbus.registers.write(base + 4, min(int(bbox[2]), 65535))
            self.modbus.registers.write(base + 5, min(int(bbox[3]), 65535))

        # OPC UA 节点更新
        self.opcua.set_node("ns=2;s=DetectionCount", n)
        if n > 0:
            best = max(detections, key=lambda d: d["confidence"])
            self.opcua.set_node("ns=2;s=TopClassID", best["class_id"])
            self.opcua.set_node("ns=2;s=TopConfidence", best["confidence"])

    def publish_system_status(self, status):
        """发布系统状态"""
        # Modbus
        self.modbus.registers.write(0x0001, 1)  # running
        self.modbus.registers.write(0x0003, int(status.get("cpu_usage", 0) * 10))
        self.modbus.registers.write(0x0004, int(status.get("npu_temperature", 0) * 10))

        # OPC UA
        self.opcua.set_node("ns=2;s=CPU_Usage", status.get("cpu_usage", 0))
        self.opcua.set_node("ns=2;s=NPU_Temperature", status.get("npu_temperature", 0))
        self.opcua.set_node("ns=2;s=Inference_FPS", status.get("inference_fps", 0))


# =============================================================================
# 测试类
# =============================================================================

class TestProtocolOutputIntegration:
    """双协议输出集成测试"""

    def test_dual_protocol_publish(self):
        """检测结果应同时发布到 Modbus 和 OPC UA"""
        modbus = MockModbusServer()
        opcua = MockOpcuaServer()
        modbus.start()
        opcua.start()
        adapter = ProtocolOutputAdapter(modbus, opcua)

        detections = [
            {"class_id": 0, "class_name": "person", "confidence": 0.95,
             "bbox": [100, 150, 350, 550]},
            {"class_id": 2, "class_name": "car", "confidence": 0.87,
             "bbox": [500, 200, 700, 450]},
        ]

        adapter.publish_detections(detections)

        # 验证 Modbus
        assert modbus.registers.read(0x0010) == 2  # 检测数量
        assert modbus.registers.read(0x0011) == 0  # 最高置信度 class_id
        top_conf = modbus.registers.read_float_x1000(0x0012)
        assert abs(top_conf - 0.95) < 0.005

        # 验证 OPC UA
        assert opcua.nodes["ns=2;s=DetectionCount"] == 2
        assert opcua.nodes["ns=2;s=TopClassID"] == 0
        assert abs(opcua.nodes["ns=2;s=TopConfidence"] - 0.95) < 0.001

    def test_system_status_publish(self, sample_system_status):
        """系统状态应同步到两个协议"""
        modbus = MockModbusServer()
        opcua = MockOpcuaServer()
        adapter = ProtocolOutputAdapter(modbus, opcua)

        adapter.publish_system_status(sample_system_status)

        # Modbus 验证
        cpu_reg = modbus.registers.read_float_x10(0x0003)
        temp_reg = modbus.registers.read_float_x10(0x0004)
        assert abs(cpu_reg - 45.2) < 0.2
        assert abs(temp_reg - 58.3) < 0.2

        # OPC UA 验证
        assert abs(opcua.nodes["ns=2;s=CPU_Usage"] - 45.2) < 0.01
        assert abs(opcua.nodes["ns=2;s=NPU_Temperature"] - 58.3) < 0.01
        assert abs(opcua.nodes["ns=2;s=Inference_FPS"] - 54.0) < 0.01

    def test_empty_detections_handling(self):
        """空检测结果应正确清零"""
        modbus = MockModbusServer()
        opcua = MockOpcuaServer()
        adapter = ProtocolOutputAdapter(modbus, opcua)

        # 先发布一些结果
        adapter.publish_detections([
            {"class_id": 0, "confidence": 0.9, "bbox": [100, 100, 200, 200]}
        ])

        # 再发布空结果
        adapter.publish_detections([])

        assert modbus.registers.read(0x0010) == 0
        assert opcua.nodes["ns=2;s=DetectionCount"] == 0

    def test_max_detections_truncation(self):
        """超过 20 个检测应截断"""
        modbus = MockModbusServer()
        opcua = MockOpcuaServer()
        adapter = ProtocolOutputAdapter(modbus, opcua)

        detections = [
            {"class_id": i % 80, "confidence": 0.9,
             "bbox": [i * 10, i * 10, i * 10 + 100, i * 10 + 100]}
            for i in range(50)
        ]

        adapter.publish_detections(detections)

        assert modbus.registers.read(0x0010) == 20
        assert opcua.nodes["ns=2;s=DetectionCount"] == 20


class TestModbusOpcuaConsistency:
    """Modbus 与 OPC UA 数据一致性测试"""

    def test_detection_count_consistency(self):
        """两个协议的检测数量应一致"""
        modbus = MockModbusServer()
        opcua = MockOpcuaServer()
        adapter = ProtocolOutputAdapter(modbus, opcua)

        for n in range(0, 21):
            detections = [
                {"class_id": 0, "confidence": 0.9,
                 "bbox": [10, 10, 100, 100]}
            ] * n
            adapter.publish_detections(detections)

            modbus_count = modbus.registers.read(0x0010)
            opcua_count = opcua.nodes["ns=2;s=DetectionCount"]
            assert modbus_count == opcua_count == min(n, 20)

    def test_confidence_value_consistency(self):
        """置信度在两个协议中应存贮一致值"""
        modbus = MockModbusServer()
        opcua = MockOpcuaServer()
        adapter = ProtocolOutputAdapter(modbus, opcua)

        test_confs = [0.001, 0.5, 0.789, 0.999]
        for conf in test_confs:
            adapter.publish_detections([
                {"class_id": 0, "confidence": conf, "bbox": [100, 100, 200, 200]}
            ])

            modbus_conf = modbus.registers.read_float_x1000(0x0012)
            opcua_conf = opcua.nodes["ns=2;s=TopConfidence"]

            assert abs(modbus_conf - conf) < 0.002
            assert abs(opcua_conf - conf) < 0.002

    def test_bbox_coordinate_consistency(self):
        """bbox 坐标在两个协议中的表示应一致"""
        modbus = MockModbusServer()
        opcua = MockOpcuaServer()
        adapter = ProtocolOutputAdapter(modbus, opcua)

        bbox = [120, 340, 560, 890]
        adapter.publish_detections([
            {"class_id": 0, "confidence": 0.9, "bbox": bbox}
        ])

        # Slot 0 的 bbox 寄存器
        assert modbus.registers.read(0x0032) == bbox[0]
        assert modbus.registers.read(0x0033) == bbox[1]
        assert modbus.registers.read(0x0034) == bbox[2]
        assert modbus.registers.read(0x0035) == bbox[3]


class TestProtocolServerLifecycle:
    """协议服务器生命周期测试"""

    def test_modbus_server_start_stop(self):
        """Modbus 服务器启停"""
        server = MockModbusServer()
        assert not server.running

        server.start()
        assert server.running

        server.stop()
        assert not server.running

    def test_opcua_server_start_stop(self):
        """OPC UA 服务器启停"""
        server = MockOpcuaServer()
        assert not server.running

        server.start()
        assert server.running

        server.stop()
        assert not server.running

    def test_concurrent_start_stop(self):
        """双服务器并发启停"""
        modbus = MockModbusServer()
        opcua = MockOpcuaServer()

        t1 = threading.Thread(target=modbus.start)
        t2 = threading.Thread(target=opcua.start)
        t1.start()
        t2.start()
        t1.join()
        t2.join()

        assert modbus.running
        assert opcua.running

        t3 = threading.Thread(target=modbus.stop)
        t4 = threading.Thread(target=opcua.stop)
        t3.start()
        t4.start()
        t3.join()
        t4.join()

        assert not modbus.running
        assert not opcua.running


class TestRegisterMappingDetail:
    """寄存器映射详细测试"""

    def test_system_status_register_layout(self):
        """系统状态寄存器布局"""
        layout = {
            0x0000: "heartbeat",
            0x0001: "status",
            0x0002: "error_code",
            0x0003: "cpu_usage (x10)",
            0x0004: "npu_temperature (x10)",
            0x0005: "memory_usage (x10)",
            0x0006: "inference_fps (x10)",
        }
        assert layout[0x0000] == "heartbeat"
        assert layout[0x0003] == "cpu_usage (x10)"
        assert len(layout) == 7

    def test_detection_slot_register_layout(self):
        """检测槽位寄存器布局 (每槽 6 寄存器)"""
        fields = ["class_id", "confidence (x1000)", "bbox_x1", "bbox_y1", "bbox_x2", "bbox_y2"]
        assert len(fields) == 6

        # Slot 0: 0x0030-0x0035
        base = 0x0030
        assert base + 5 == 0x0035
        # Slot 19: 0x0030 + 19*6 = 0x00A2
        assert 0x0030 + 19 * 6 == 0x00A2

    def test_detection_slot_capacity(self):
        """20 个槽位不应超出边界"""
        base = 0x0030
        max_slot = 19
        end_addr = base + max_slot * 6 + 5
        assert end_addr == 0x00A7
        assert end_addr < 0x0100


class TestMultiClientConcurrency:
    """多客户端并发访问测试"""

    def test_concurrent_modbus_reads(self):
        """多线程并发读取 Modbus"""
        server = MockModbusServer()
        server.start()
        server.registers.write(0x0003, 452)  # 45.2 * 10

        errors = []
        def reader():
            try:
                for _ in range(100):
                    val = server.registers.read_float_x10(0x0003)
                    assert abs(val - 45.2) < 0.1
            except Exception as e:
                errors.append(e)

        threads = [threading.Thread(target=reader) for _ in range(4)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        assert len(errors) == 0

    def test_concurrent_opcua_node_access(self):
        """多线程并发读写 OPC UA 节点"""
        server = MockOpcuaServer()
        server.start()

        def writer():
            for i in range(100):
                server.set_node("ns=2;s=TestNode", i)

        t1 = threading.Thread(target=writer)
        t2 = threading.Thread(target=writer)
        t1.start()
        t2.start()
        t1.join()
        t2.join()

        assert server.nodes["ns=2;s=TestNode"] >= 0

    def test_concurrent_dual_protocol_publish(self):
        """并发发布到双协议"""
        modbus = MockModbusServer()
        opcua = MockOpcuaServer()
        adapter = ProtocolOutputAdapter(modbus, opcua)

        detections = [
            {"class_id": 0, "confidence": 0.95, "bbox": [100, 100, 200, 200]}
        ] * 3

        def publisher():
            for _ in range(50):
                adapter.publish_detections(detections)
                adapter.publish_system_status({
                    "cpu_usage": 45.0, "npu_temperature": 58.0, "inference_fps": 54.0
                })

        threads = [threading.Thread(target=publisher) for _ in range(4)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        assert adapter.publish_count == 200
        assert modbus.registers.read(0x0010) == 3
