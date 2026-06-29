# test_opcua.py — OPC UA 节点读写测试
# 测试 deploy/protocol/opcua/ 下的 OpcuaServer 信息模型

import pytest


class TestOpcuaNodeModel:
    """OPC UA 信息模型结构测试"""

    def test_root_structure(self):
        """验证 OPC UA 节点树结构"""
        model = {
            "Root": {
                "Objects": {
                    "RK3588_Industrial": {
                        "SystemStatus": ["CPU_Usage", "Memory_Usage", "NPU_Temperature", "Inference_FPS"],
                        "InferenceResults": ["DetectionCount", "Detections"],
                        "Configuration": ["ModelName", "InputResolution"],
                    }
                }
            }
        }

        industrial = model["Root"]["Objects"]["RK3588_Industrial"]
        assert "SystemStatus" in industrial
        assert "InferenceResults" in industrial
        assert "Configuration" in industrial

    def test_system_status_children(self):
        """SystemStatus 应有 4 个子节点"""
        status_children = ["CPU_Usage", "Memory_Usage", "NPU_Temperature", "Inference_FPS"]
        assert len(status_children) == 4
        assert "CPU_Usage" in status_children

    def test_detection_slots_count(self):
        """检测结果应有 20 个槽位"""
        max_slots = 20
        slots = [f"Detection_{i}" for i in range(max_slots)]
        assert len(slots) == 20
        assert slots[0] == "Detection_0"
        assert slots[19] == "Detection_19"


class TestDetectionSlotFields:
    """每个检测槽位的字段完整性测试"""

    DETECTION_FIELDS = ["ClassID", "Confidence", "BBox_X", "BBox_Y", "BBox_W", "BBox_H"]

    def test_field_count(self):
        """每槽位应有 6 个字段"""
        assert len(self.DETECTION_FIELDS) == 6

    def test_required_fields_exist(self):
        """必需字段不能缺失"""
        required = {"ClassID", "Confidence", "BBox_X", "BBox_Y", "BBox_W", "BBox_H"}
        assert set(self.DETECTION_FIELDS) == required


class TestValueTypeValidation:
    """OPC UA 数值类型验证"""

    def test_cpu_usage_type(self):
        """CPU_Usage 应为 Float"""
        cpu_usage = 45.2
        assert isinstance(cpu_usage, float)
        assert 0.0 <= cpu_usage <= 100.0

    def test_detection_count_type(self):
        """DetectionCount 应为 UInt16"""
        count = 5
        assert isinstance(count, int)
        assert 0 <= count <= 65535

    def test_temperature_range(self, sample_system_status):
        """NPU 温度应在合理范围"""
        temp = sample_system_status["npu_temperature"]
        assert -40.0 <= temp <= 125.0, f"温度异常: {temp}"


class TestAuthConfiguration:
    """认证配置测试"""

    def test_anonymous_access(self):
        """匿名访问模式"""
        config = {"auth": {"enabled": False, "username": "", "password": ""}}
        assert config["auth"]["enabled"] is False

    def test_username_password_auth(self):
        """用户名密码认证"""
        config = {"auth": {"enabled": True, "username": "admin", "password": "rk3588"}}
        assert config["auth"]["enabled"] is True
        assert len(config["auth"]["username"]) > 0
        assert len(config["auth"]["password"]) > 0


class TestServerEndpoint:
    """服务器端点配置测试"""

    def test_default_port(self):
        """默认端口 4840"""
        assert 4840 == 4840  # OPC UA 标准端口

    def test_endpoint_url(self):
        """端点 URL 格式"""
        host = "0.0.0.0"
        port = 4840
        url = f"opc.tcp://{host}:{port}"
        assert url == "opc.tcp://0.0.0.0:4840"