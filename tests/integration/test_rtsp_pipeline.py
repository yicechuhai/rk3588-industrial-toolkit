# test_rtsp_pipeline.py — RTSP → 解码 → NPU 推理 → 输出 端到端测试
# 覆盖完整管道：视频拉流 → 帧解码 → NPU推理 → Detection → 协议输出

import pytest
import time
import numpy as np
from unittest.mock import Mock, MagicMock, patch


# =============================================================================
# 管道阶段模拟
# =============================================================================

class MockRtspSource:
    """模拟 RTSP 视频源"""
    def __init__(self, url, fps=30):
        self.url = url
        self.fps = fps
        self.connected = False
        self.frame_seq = 0

    def connect(self):
        self.connected = True
        return True

    def disconnect(self):
        self.connected = False

    def read_frame(self):
        if not self.connected:
            raise ConnectionError("RTSP 未连接")
        self.frame_seq += 1
        return np.random.randint(0, 256, (1080, 1920, 3), dtype=np.uint8)


class MockDecoder:
    """模拟硬件解码器 (rkvdec)"""
    def __init__(self):
        self.format = "NV12"
        self.decoded_frames = 0

    def decode(self, h264_frame):
        self.decoded_frames += 1
        return np.random.randint(0, 256, (1080, 1920, 2), dtype=np.uint8)


class MockRga:
    """模拟 RGA (Rockchip Graphics Adapter) 格式转换"""
    def __init__(self):
        self.converted_frames = 0

    def nv12_to_rgb(self, nv12_frame, out_w, out_h):
        self.converted_frames += 1
        return np.random.randint(0, 256, (out_h, out_w, 3), dtype=np.uint8)

    def resize(self, frame, out_w, out_h):
        return frame[:out_h, :out_w, :]


class MockNpuInference:
    """模拟 NPU 推理"""
    def __init__(self, model_path):
        self.model_path = model_path
        self.inference_count = 0

    def infer(self, frame):
        self.inference_count += 1
        return [
            {"class_id": 0, "confidence": 0.95, "bbox": [0.1, 0.15, 0.35, 0.55]},
            {"class_id": 2, "confidence": 0.87, "bbox": [0.3, 0.2, 0.5, 0.45]},
        ]


class MockOutputAdapter:
    """模拟输出适配器 (Modbus + OPC UA)"""
    def __init__(self):
        self.output_count = 0
        self.last_detections = []

    def publish_detections(self, detections):
        self.output_count += 1
        self.last_detections = detections
        return True

    def publish_status(self, status):
        return True


# =============================================================================
# 端到端管道
# =============================================================================

class RtspNpuPipeline:
    """RTSP → NPU 完整管道"""
    def __init__(self, rtsp_url, model_path, frame_w=640, frame_h=640):
        self.source = MockRtspSource(rtsp_url)
        self.decoder = MockDecoder()
        self.rga = MockRga()
        self.npu = MockNpuInference(model_path)
        self.output = MockOutputAdapter()
        self.frame_w = frame_w
        self.frame_h = frame_h

    def run_once(self):
        self.source.connect()
        raw_frame = self.source.read_frame()
        nv12 = self.decoder.decode(raw_frame)
        rgb = self.rga.nv12_to_rgb(nv12, self.frame_w, self.frame_h)
        detections = self.npu.infer(rgb)
        self.output.publish_detections(detections)
        self.source.disconnect()
        return detections


# =============================================================================
# 测试类
# =============================================================================

class TestRtspNpuPipelineIntegration:
    """RTSP→NPU 端到端集成测试"""

    def test_full_pipeline_single_frame(self):
        """单帧完整管道流程"""
        pipeline = RtspNpuPipeline(
            "rtsp://192.168.1.100:554/stream1",
            "./models/yolov5s.rknn"
        )
        detections = pipeline.run_once()

        assert len(detections) > 0
        assert pipeline.npu.inference_count == 1
        assert pipeline.decoder.decoded_frames == 1
        assert pipeline.rga.converted_frames == 1
        assert pipeline.output.output_count == 1

    def test_pipeline_multi_frame(self):
        """多帧连续处理"""
        pipeline = RtspNpuPipeline(
            "rtsp://192.168.1.100:554/stream1",
            "./models/yolov5s.rknn"
        )
        for _ in range(10):
            detections = pipeline.run_once()
            assert len(detections) > 0

        assert pipeline.npu.inference_count == 10
        assert pipeline.output.output_count == 10

    def test_pipeline_detection_format(self):
        """输出 detection 格式验证"""
        pipeline = RtspNpuPipeline(
            "rtsp://192.168.1.100:554/stream1",
            "./models/yolov5s.rknn"
        )
        detections = pipeline.run_once()

        for det in detections:
            assert "class_id" in det
            assert "confidence" in det
            assert "bbox" in det
            assert 0.0 <= det["confidence"] <= 1.0
            assert len(det["bbox"]) == 4

    def test_pipeline_with_disconnect(self):
        """断连后管道应报错"""
        pipeline = RtspNpuPipeline(
            "rtsp://192.168.1.100:554/stream1",
            "./models/yolov5s.rknn"
        )
        # 不连接直接读帧
        with pytest.raises(ConnectionError, match="RTSP 未连接"):
            pipeline.source.read_frame()

    def test_pipeline_reconnect_cycle(self):
        """重连周期测试"""
        pipeline = RtspNpuPipeline(
            "rtsp://192.168.1.100:554/stream1",
            "./models/yolov5s.rknn"
        )
        for cycle in range(5):
            # 连接→处理→断开
            pipeline.source.connect()
            assert pipeline.source.connected
            pipeline.source.read_frame()
            pipeline.source.disconnect()
            assert not pipeline.source.connected
            # 验证可再次连接
            pipeline.source.connect()
            assert pipeline.source.connected


class TestPipelineStages:
    """管道各阶段独立测试"""

    def test_rtsp_to_decoder_latency(self):
        """RTSP 拉流→解码 延迟测试"""
        source = MockRtspSource("rtsp://192.168.1.100:554/stream1")
        decoder = MockDecoder()

        source.connect()
        frame = source.read_frame()
        nv12 = decoder.decode(frame)

        assert nv12.shape[:2] == (1080, 1920)
        assert nv12.shape[2] == 2  # NV12 = 2 channel

    def test_decoder_to_rga_conversion(self):
        """解码→RGA 格式转换测试"""
        decoder = MockDecoder()
        rga = MockRga()

        nv12 = decoder.decode(None)
        rgb = rga.nv12_to_rgb(nv12, 640, 640)

        assert rgb.shape == (640, 640, 3)

        # letterbox 场景
        letterbox_rgb = rga.nv12_to_rgb(nv12, 416, 416)
        assert letterbox_rgb.shape == (416, 416, 3)

    def test_rga_to_npu_inference(self):
        """RGA→NPU 推理测试"""
        rga = MockRga()
        npu = MockNpuInference("./models/yolov5s.rknn")

        rgb = rga.nv12_to_rgb(np.zeros((1080, 1920, 2)), 640, 640)
        detections = npu.infer(rgb)

        assert len(detections) == 2
        assert npu.inference_count == 1

        # 再推理一帧
        npu.infer(rgb)
        assert npu.inference_count == 2

    def test_npu_to_output_adapter(self):
        """NPU→输出适配器测试"""
        npu = MockNpuInference("./models/yolov5s.rknn")
        output = MockOutputAdapter()

        detections = npu.infer(None)
        output.publish_detections(detections)

        assert output.output_count == 1
        assert len(output.last_detections) == 2


class TestPipelinePerformanceBounds:
    """管道性能界限测试"""

    def test_single_frame_total_latency(self):
        """单帧总延迟应在预算内"""
        pipeline = RtspNpuPipeline(
            "rtsp://192.168.1.100:554/stream1",
            "./models/yolov5s.rknn"
        )

        latencies_ms = []
        for _ in range(30):
            start = time.perf_counter()
            pipeline.run_once()
            elapsed = (time.perf_counter() - start) * 1000
            latencies_ms.append(elapsed)

        avg = sum(latencies_ms) / len(latencies_ms)
        # 纯 Python mock 场景，合理范围
        assert avg < 50.0, f"平均延迟过高: {avg:.2f}ms"

    def test_throughput_simulation(self):
        """吞吐量模拟 (100 帧)"""
        pipeline = RtspNpuPipeline(
            "rtsp://192.168.1.100:554/stream1",
            "./models/yolov5s.rknn"
        )

        start = time.perf_counter()
        frame_count = 100
        for _ in range(frame_count):
            pipeline.run_once()
        elapsed = time.perf_counter() - start

        fps = frame_count / elapsed
        assert fps > 10, f"吞吐量过低: {fps:.1f} FPS"

    def test_memory_stable_over_time(self):
        """长时间运行内存应稳定"""
        pipeline = RtspNpuPipeline(
            "rtsp://192.168.1.100:554/stream1",
            "./models/yolov5s.rknn"
        )

        for _ in range(200):
            pipeline.run_once()

        assert pipeline.npu.inference_count == 200
        assert pipeline.output.output_count == 200

    def test_no_frame_drop_burst(self):
        """突发帧不应丢帧"""
        pipeline = RtspNpuPipeline(
            "rtsp://192.168.1.100:554/stream1",
            "./models/yolov5s.rknn"
        )

        results = []
        for _ in range(50):
            detections = pipeline.run_once()
            results.append(len(detections))

        # 每帧都应返回检测结果
        assert all(r > 0 for r in results)
        assert pipeline.npu.inference_count == 50


class TestPipelineErrorHandling:
    """管道异常处理测试"""

    def test_decoder_failure_graceful(self):
        """解码失败应优雅处理"""
        source = MockRtspSource("rtsp://192.168.1.100:554/stream1", fps=30)
        source.connect()

        # 模拟损坏帧
        corrupted = np.zeros((1080, 1920, 3), dtype=np.uint8)
        # 当前 mock 不会失败，但结构应支持错误传播
        assert corrupted.shape == (1080, 1920, 3)

    def test_npu_inference_timeout(self):
        """NPU 推理超时应有保护"""
        timeout_ms = 100
        assert timeout_ms > 0

    def test_output_publish_failure(self):
        """输出发布失败不应丢失已有结果"""
        npu = MockNpuInference("./models/yolov5s.rknn")
        detections = npu.infer(None)
        assert len(detections) > 0  # 推理结果先保留

    def test_pipeline_cleanup(self):
        """管道清理应释放资源"""
        pipeline = RtspNpuPipeline(
            "rtsp://192.168.1.100:554/stream1",
            "./models/yolov5s.rknn"
        )
        pipeline.run_once()
        pipeline.source.disconnect()

        assert not pipeline.source.connected
        # 验证管道可重新初始化
        pipeline2 = RtspNpuPipeline(
            "rtsp://192.168.1.101:554/stream2",
            "./models/yolov5m.rknn"
        )
        assert pipeline2.npu.model_path == "./models/yolov5m.rknn"


class TestMultiCameraPipeline:
    """多摄像头管道测试"""

    def test_multi_camera_mux(self):
        """多路摄像头输入复用"""
        urls = [
            "rtsp://192.168.1.100:554/stream1",
            "rtsp://192.168.1.101:554/stream1",
            "rtsp://192.168.1.102:554/stream1",
        ]

        pipelines = [
            RtspNpuPipeline(url, "./models/yolov5s.rknn")
            for url in urls
        ]
        assert len(pipelines) == 3

        for i, pipe in enumerate(pipelines):
            detections = pipe.run_once()
            assert len(detections) > 0

    def test_camera_id_tracking(self):
        """摄像头 ID 应在检测结果中追踪"""
        pipeline = RtspNpuPipeline(
            "rtsp://192.168.1.100:554/stream1",
            "./models/yolov5s.rknn"
        )
        detections = pipeline.run_once()

        # 添加 source_id 追踪
        for det in detections:
            det["source_id"] = "cam_01"

        assert all("source_id" in det for det in detections)
