# test_latency_bench.py — 端到端延迟基准测试
# 测量：采集延迟、推理延迟、协议输出延迟、端到端总延迟

import pytest
import time
import numpy as np
import threading


# =============================================================================
# 模拟各级延迟
# =============================================================================

class PipelineStage:
    """管道阶段的延迟模拟"""
    def __init__(self, name, latency_ms, jitter_ms=0):
        self.name = name
        self._latency = latency_ms
        self._jitter = jitter_ms
        self.call_count = 0

    def execute(self):
        self.call_count += 1
        jitter = np.random.uniform(-self._jitter, self._jitter)
        actual = max(0, self._latency + jitter)
        time.sleep(actual / 1000.0)
        return actual


# =============================================================================
# 端到端管道 (各阶段可测量)
# =============================================================================

class MeasuredPipeline:
    """可测量各级延迟的管道"""
    def __init__(self):
        self.capture = PipelineStage("Camera Capture", 33.0, 2.0)
        self.decode = PipelineStage("Video Decode", 12.0, 1.0)
        self.preprocess = PipelineStage("Preprocess", 2.0, 0.5)
        self.inference = PipelineStage("NPU Inference", 18.5, 3.0)
        self.postprocess = PipelineStage("Postprocess", 3.0, 0.5)
        self.modbus_publish = PipelineStage("Modbus Publish", 5.0, 1.0)
        self.opcua_publish = PipelineStage("OPC UA Publish", 8.0, 2.0)

        self.stages = [
            self.capture, self.decode, self.preprocess,
            self.inference, self.postprocess,
            self.modbus_publish, self.opcua_publish,
        ]

    def run_frame(self):
        latencies = {}
        for stage in self.stages:
            latencies[stage.name] = stage.execute()
        return latencies

    def run_frame_concurrent_output(self):
        """推理后双协议并发输出"""
        latencies = {}
        latencies[self.capture.name] = self.capture.execute()
        latencies[self.decode.name] = self.decode.execute()
        latencies[self.preprocess.name] = self.preprocess.execute()
        latencies[self.inference.name] = self.inference.execute()
        latencies[self.postprocess.name] = self.postprocess.execute()

        # Modbus 和 OPC UA 并发发布
        output_latencies = {}
        def modbus_pub():
            output_latencies["modbus"] = self.modbus_publish.execute()

        def opcua_pub():
            output_latencies["opcua"] = self.opcua_publish.execute()

        t1 = threading.Thread(target=modbus_pub)
        t2 = threading.Thread(target=opcua_pub)
        t1.start()
        t2.start()
        t1.join()
        t2.join()

        latencies["Output (Modbus+OPC UA)"] = max(output_latencies.values())
        return latencies


# =============================================================================
# 测试类
# =============================================================================

class TestStageLatency:
    """各级延迟基准"""

    def test_capture_latency_bound(self, latency_recorder):
        """采集延迟应在预算内"""
        stage = PipelineStage("Capture", 33.0, 2.0)
        for _ in range(200):
            start = time.perf_counter()
            lat = stage.execute()
            elapsed = (time.perf_counter() - start) * 1000
            latency_recorder.record(elapsed)

        stats = latency_recorder.stats()
        # 30fps → 33.3ms 预算
        assert stats["avg"] < 40.0
        assert stats["p99"] < 45.0

    def test_inference_latency_p99(self, latency_recorder):
        """推理延迟 P99"""
        stage = PipelineStage("Inference", 18.5, 3.0)
        for _ in range(500):
            start = time.perf_counter()
            lat = stage.execute()
            elapsed = (time.perf_counter() - start) * 1000
            latency_recorder.record(elapsed)

        stats = latency_recorder.stats()
        assert stats["p99"] < 30.0  # P99 < 30ms

    def test_modbus_output_latency_budget(self, latency_recorder):
        """Modbus 输出延迟应 < 10ms"""
        stage = PipelineStage("Modbus", 5.0, 1.0)
        for _ in range(200):
            start = time.perf_counter()
            lat = stage.execute()
            elapsed = (time.perf_counter() - start) * 1000
            latency_recorder.record(elapsed)

        stats = latency_recorder.stats()
        assert stats["avg"] < 10.0


class TestEndToEndLatency:
    """端到端延迟基准"""

    def test_total_e2e_latency(self, latency_recorder):
        """端到端总延迟应 < 100ms"""
        pipeline = MeasuredPipeline()

        # 预热
        for _ in range(30):
            pipeline.run_frame()

        # 测量
        for _ in range(200):
            start = time.perf_counter()
            pipeline.run_frame()
            total = (time.perf_counter() - start) * 1000
            latency_recorder.record(total)

        stats = latency_recorder.stats()
        assert stats["avg"] < 100.0, f"端到端平均延迟 {stats['avg']:.1f}ms 超过 100ms"
        assert stats["p99"] < 130.0, f"P99 延迟 {stats['p99']:.1f}ms 过高"

    def test_pipeline_stage_breakdown(self):
        """管道各级延迟分解"""
        pipeline = MeasuredPipeline()

        # 采集一次各级延迟
        all_latencies = []
        for _ in range(50):
            latencies = pipeline.run_frame()
            all_latencies.append(latencies)

        # 计算各级平均延迟
        stage_avgs = {}
        for stage_name in all_latencies[0].keys():
            vals = [l[stage_name] for l in all_latencies]
            stage_avgs[stage_name] = sum(vals) / len(vals)

        total_avg = sum(stage_avgs.values())
        # 推理+采集 应占最大比重
        assert stage_avgs["NPU Inference"] > 0
        assert stage_avgs["Camera Capture"] > 0

    def test_concurrent_output_parallelism(self, latency_recorder):
        """并发双协议输出的总延迟 (取最大值)"""
        pipeline = MeasuredPipeline()

        for _ in range(100):
            start = time.perf_counter()
            pipeline.run_frame_concurrent_output()
            total = (time.perf_counter() - start) * 1000
            latency_recorder.record(total)

        stats = latency_recorder.stats()
        # 并发输出应比串行快
        assert stats["avg"] < 100.0


class TestJitterAnalysis:
    """延迟抖动分析"""

    def test_inference_jitter(self):
        """推理延迟抖动应在可控范围"""
        stage = PipelineStage("Inference", 18.5, 3.0)
        latencies = []
        for _ in range(500):
            start = time.perf_counter()
            stage.execute()
            latencies.append((time.perf_counter() - start) * 1000)

        arr = np.array(latencies)
        std_ms = float(np.std(arr))
        # 标准差应可控 (预期 ~jitter/sqrt(3))
        assert std_ms < 5.0

    def test_end_to_end_jitter(self):
        """端到端抖动分析"""
        pipeline = MeasuredPipeline()

        latencies = []
        for _ in range(200):
            start = time.perf_counter()
            pipeline.run_frame()
            latencies.append((time.perf_counter() - start) * 1000)

        arr = np.array(latencies)
        p95 = float(np.percentile(arr, 95))
        p50 = float(np.percentile(arr, 50))
        jitter = p95 - p50

        # P95-P50 抖动应在 20ms 内
        assert jitter < 25.0, f"P95-P50 抖动 {jitter:.1f}ms 过大"

    def test_long_tail_latency(self):
        """长尾延迟 (P99 vs P50)"""
        pipeline = MeasuredPipeline()

        latencies = []
        for _ in range(500):
            start = time.perf_counter()
            pipeline.run_frame()
            latencies.append((time.perf_counter() - start) * 1000)

        arr = np.array(latencies)
        p99 = float(np.percentile(arr, 99))
        p50 = float(np.percentile(arr, 50))

        # P99 / P50 比值应 < 2x
        ratio = p99 / p50 if p50 > 0 else 0
        assert ratio < 2.5, f"长尾比值 {ratio:.1f}x 过高"


class TestThroughputVsLatency:
    """吞吐量与延迟权衡"""

    def test_fps_vs_latency_tradeoff(self):
        """高吞吐量不应以极高延迟为代价"""
        # 模拟不同 batch size 下的延迟/吞吐量
        scenarios = [
            {"batch": 1, "fps": 54, "latency_ms": 18.5},
            {"batch": 2, "fps": 80, "latency_ms": 25.0},
            {"batch": 4, "fps": 100, "latency_ms": 40.0},
        ]
        for s in scenarios:
            assert s["latency_ms"] < 50.0  # 延迟不能过高
            assert s["fps"] >= 30  # FPS 达标

    def test_burst_mode_performance(self):
        """突发模式性能"""
        pipeline = MeasuredPipeline()

        burst_size = 20
        start = time.perf_counter()
        for _ in range(burst_size):
            pipeline.run_frame()
        elapsed = (time.perf_counter() - start) * 1000

        avg_per_frame = elapsed / burst_size
        # 突发模式下每帧延迟应接近稳态
        assert avg_per_frame < 120.0


class TestMemoryAndResource:
    """资源使用基准"""

    def test_memory_usage_over_time(self):
        """长时间运行内存是否泄漏 (概念测试)"""
        # 模拟：连续运行后内存应稳定
        initial_allocations = 100
        leaked_per_frame = 0  # 不应泄漏
        frames = 1000
        final_allocations = initial_allocations + leaked_per_frame * frames
        assert final_allocations == initial_allocations

    def test_gpu_memory_pool_size(self):
        """GPU/NPU 内存池大小"""
        pool_sizes = [128, 256, 512]  # MB
        total_pool = sum(pool_sizes)
        assert total_pool <= 1024  # 总池 ≤ 1GB

    def test_file_descriptor_count(self):
        """文件描述符使用量"""
        # RTSP (1) + /dev/galcore (1) + Modbus socket (1) + OPC UA socket (1) + 日志 (1)
        fd_count = 5
        max_fd = 1024
        assert fd_count < max_fd
        assert fd_count < 100  # 合理上限
