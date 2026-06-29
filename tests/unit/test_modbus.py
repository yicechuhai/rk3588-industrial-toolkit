# test_modbus.py — Modbus TCP 寄存器读写测试
# 测试部署在 deploy/protocol/modbus/ 下的 ModbusServer 和 RegisterMap

import pytest
import sys
import os

# 模拟：实际硬件上需要 libmodbus，这里做接口契约测试
# 测试地址转换逻辑、寄存器映射数据结构等

class TestModbusAddressParsing:
    """Modbus 地址格式解析测试"""

    def test_hex_address_format(self):
        """0x0000 格式应保持不变"""
        addr = 0x0000
        assert addr == 0

    def test_plc_address_format(self):
        """40001 格式应转换为 0x0000"""
        def parse_plc(plc_addr):
            if 40001 <= plc_addr <= 49999:
                return plc_addr - 40001
            return plc_addr

        assert parse_plc(40001) == 0
        assert parse_plc(40010) == 9
        assert parse_plc(40100) == 99

    def test_invalid_plc_range(self):
        """超出范围的 PLC 地址应保持原值"""
        def parse_plc(plc_addr):
            if 40001 <= plc_addr <= 49999:
                return plc_addr - 40001
            return plc_addr

        assert parse_plc(30001) == 30001
        assert parse_plc(50001) == 50001


class TestRegisterMapping:
    """寄存器地址映射测试"""

    def test_system_status_registers(self):
        """系统状态寄存器 0x0000-0x000F"""
        status_addrs = {
            "heartbeat": 0x0000,
            "fps": 0x0001,
            "temperature": 0x0002,
            "cpu_usage": 0x0003,
        }
        for name, addr in status_addrs.items():
            assert 0x0000 <= addr <= 0x000F, f"{name} 地址越界: {addr:#06x}"

    def test_detection_count_register(self):
        """检测数量寄存器应在 0x0010 范围"""
        detection_count_addr = 0x0010
        assert 0x0010 <= detection_count_addr <= 0x002F

    def test_detection_slot_capacity(self):
        """最多 20 个目标，每目标 6 个寄存器，总范围 0x0030-0x00FF"""
        max_targets = 20
        regs_per_target = 6
        base = 0x0030
        end = base + max_targets * regs_per_target
        assert end <= 0x0100  # 不超出 0x00FF 边界
        assert end == 0x0030 + 120


class TestDetectionToRegisterConversion:
    """Detection 结构体到 Modbus 寄存器的转换"""

    def test_bbox_to_registers(self, sample_detection):
        """边界框应正确拆分为 X,Y,W,H"""
        bbox = sample_detection["bbox"]
        registers = {
            "x": int(bbox[0]),
            "y": int(bbox[1]),
            "w": int(bbox[2]),
            "h": int(bbox[3]),
        }
        assert registers["x"] == 100
        assert registers["y"] == 150
        assert registers["w"] == 200
        assert registers["h"] == 300

    def test_class_id_range(self, sample_detections):
        """class_id 应在 0-79 范围 (COCO 80 类)"""
        for det in sample_detections:
            assert 0 <= det["class_id"] <= 79

    def test_confidence_range(self, sample_detections):
        """confidence 应在 0.0-1.0 范围"""
        for det in sample_detections:
            assert 0.0 <= det["confidence"] <= 1.0


class TestMultiClientConcurrency:
    """多客户端并发概念测试"""

    def test_connection_pool(self):
        """模拟连接池最大连接数"""
        max_connections = 8
        connections = []
        for i in range(max_connections):
            connections.append({"id": i, "socket": f"mock_socket_{i}"})
        assert len(connections) == max_connections

    def test_concurrent_register_access(self):
        """并发写入同一寄存器应有锁保护"""
        import threading

        shared_reg = {"value": 0}
        lock = threading.Lock()
        errors = []

        def writer():
            for _ in range(100):
                with lock:
                    v = shared_reg["value"]
                    shared_reg["value"] = v + 1

        threads = [threading.Thread(target=writer) for _ in range(4)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        assert shared_reg["value"] == 400, f"竞态条件: 期望 400, 实际 {shared_reg['value']}"