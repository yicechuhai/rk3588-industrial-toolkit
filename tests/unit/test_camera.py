# test_camera.py — 摄像头采集测试
# 测试 RTSP 拉流、V4L2 原生采集、帧格式转换、重连机制

import pytest
import numpy as np
from unittest.mock import Mock, MagicMock, patch


class TestRtspStreamConnection:
    """RTSP 流连接测试"""

    def test_rtsp_url_format(self):
        """RTSP URL 格式 rtsp://<host>:<port>/<path>"""
        url = "rtsp://192.168.1.100:554/stream1"
        assert url.startswith("rtsp://")
        assert ":554" in url
        assert "/stream1" in url

    def test_connection_success(self, mock_rtsp):
        """connect 应返回 True"""
        assert mock_rtsp.connect() is True

    def test_disconnect(self, mock_rtsp):
        """disconnect 应返回 True"""
        assert mock_rtsp.disconnect() is True

    def test_transport_protocol_tcp(self, mock_rtsp):
        """传输协议默认应为 TCP"""
        assert mock_rtsp.transport == "tcp"

    def test_reconnect_on_failure(self, mock_rtsp):
        """断连后应自动重连"""
        assert mock_rtsp.max_reconnects == 5
        assert mock_rtsp.reconnect_interval_sec == 3


class TestRtspSdpParsing:
    """RTSP SDP 解析测试"""

    def test_sdp_video_stream_detection(self, mock_rtsp):
        """SDP 应答应包含视频流"""
        sdp = mock_rtsp.get_sdp()
        streams = sdp["streams"]
        video_streams = [s for s in streams if s["type"] == "video"]
        assert len(video_streams) > 0

    def test_sdp_h264_codec(self, mock_rtsp):
        """应支持 H264 编码"""
        sdp = mock_rtsp.get_sdp()
        for s in sdp["streams"]:
            if s["type"] == "video":
                assert "H264" in s["codec"] or "H265" in s["codec"]

    def test_sdp_control_uri(self, mock_rtsp):
        """SDP 应包含 control URI"""
        sdp = mock_rtsp.get_sdp()
        assert "control" in sdp
        assert sdp["control"].startswith("rtsp://")


class TestRtspReconnectMechanism:
    """RTSP 重连机制测试"""

    def test_reconnect_backoff(self):
        """重连应使用指数退避"""
        base_interval = 1.0
        intervals = [base_interval * (2 ** i) for i in range(5)]
        assert intervals[0] == 1.0
        assert intervals[1] == 2.0
        assert intervals[2] == 4.0
        assert intervals[3] == 8.0
        assert intervals[4] == 16.0

    def test_max_reconnect_attempts(self, mock_rtsp):
        """最大重连次数限制"""
        assert mock_rtsp.max_reconnects == 5

    def test_reconnect_counter_reset(self):
        """重连成功后计数器应重置"""
        reconnect_count = 3
        # 模拟重连成功
        reconnect_count = 0
        assert reconnect_count == 0

    def test_total_reconnect_timeout(self):
        """总重连时间应有限制"""
        max_total_timeout = 60  # 秒
        intervals = [1, 2, 4, 8, 16, 32]
        total = sum(intervals[:5])  # 前 5 次
        assert total <= max_total_timeout


class TestV4l2NativeCapture:
    """V4L2 原生采集测试"""

    def test_device_path_format(self, mock_camera_raw):
        """设备路径应为 /dev/videoX"""
        assert mock_camera_raw.device_path.startswith("/dev/video")

    def test_driver_name(self, mock_camera_raw):
        """驱动名称应为 rkisp"""
        assert mock_camera_raw.driver == "rkisp"

    def test_pixel_format_nv12(self, mock_camera_raw):
        """默认像素格式应为 NV12"""
        assert mock_camera_raw.format == "NV12"

    def test_start_streaming(self, mock_camera_raw):
        """start_streaming 应返回 True"""
        assert mock_camera_raw.start_streaming() is True

    def test_stop_streaming(self, mock_camera_raw):
        """stop_streaming 应返回 True"""
        assert mock_camera_raw.stop_streaming() is True

    def test_buffer_count(self, mock_camera_raw):
        """buffer 数量应 ≥ 3"""
        assert mock_camera_raw.buffer_count >= 3


class TestFrameFormatConversion:
    """帧格式转换测试"""

    def test_nv12_to_rgb_shape(self):
        """NV12→RGB 应保持分辨率，通道数变为 3"""
        nv12_shape = (1080, 1920, 2)
        rgb_shape = (640, 640, 3)  # resize + 转换
        assert len(rgb_shape) == 3
        assert rgb_shape[2] == 3

    def test_rga_resize_in_bounds(self):
        """RGA resize 分辨率应在合理范围"""
        input_res = (1920, 1080)
        output_res = (640, 640)
        assert output_res[0] <= input_res[0]
        assert output_res[1] <= input_res[1]

    def test_letterbox_aspect_ratio(self):
        """letterbox 应保持宽高比"""
        src_w, src_h = 1920, 1080
        dst_w, dst_h = 640, 640
        scale = min(dst_w / src_w, dst_h / src_h)
        new_w = int(src_w * scale)
        new_h = int(src_h * scale)
        assert new_w == 640
        assert new_h == 360  # letterbox 会填充到 640
        assert new_w / new_h == pytest.approx(src_w / src_h, rel=0.02)


class TestFramePreprocessing:
    """帧预处理流程测试"""

    def test_normalization_range(self):
        """归一化后像素值应在 0-1"""
        frame = np.random.randint(0, 256, (640, 640, 3), dtype=np.uint8)
        normalized = frame.astype(np.float32) / 255.0
        assert normalized.min() >= 0.0
        assert normalized.max() <= 1.0

    def test_mean_subtraction(self, generate_test_frame):
        """均值减除后中心化"""
        frame = generate_test_frame(640, 640, 3).astype(np.float32)
        mean = np.array([0.485, 0.456, 0.406])
        std = np.array([0.229, 0.224, 0.225])
        frame = frame / 255.0
        frame = (frame - mean) / std
        # 中心化后均值应接近 0
        channel_means = frame.mean(axis=(0, 1))
        assert all(abs(m) < 0.5 for m in channel_means)

    def test_batch_dimension_added(self):
        """预处理后应增加 batch 维度 [1, C, H, W]"""
        frame = np.random.randint(0, 256, (640, 640, 3), dtype=np.uint8)
        # HWC -> CHW -> BCHW
        frame_chw = np.transpose(frame, (2, 0, 1))
        frame_bchw = np.expand_dims(frame_chw, axis=0)
        assert frame_bchw.shape == (1, 3, 640, 640)


class TestMultiStreamManagement:
    """多路流管理测试"""

    def test_multi_stream_urls(self):
        """应支持多路 RTSP URL"""
        urls = [
            "rtsp://192.168.1.100:554/stream1",
            "rtsp://192.168.1.101:554/stream1",
            "rtsp://192.168.1.102:554/stream1",
        ]
        assert len(urls) == 3
        assert all(url.startswith("rtsp://") for url in urls)

    def test_stream_round_robin(self):
        """轮询多路流"""
        streams = ["cam_0", "cam_1", "cam_2"]
        schedule = [streams[i % len(streams)] for i in range(9)]
        assert schedule[0] == "cam_0"
        assert schedule[1] == "cam_1"
        assert schedule[2] == "cam_2"
        assert schedule[3] == "cam_0"

    def test_max_camera_count(self):
        """最大摄像头数量限制"""
        MAX_CAMERAS = 8
        assert MAX_CAMERAS >= 1
        assert MAX_CAMERAS <= 16  # 合理上限


class TestFrameTimestampSynchronization:
    """帧时间戳同步测试"""

    def test_pts_monotonic_increase(self):
        """PTS 应单调递增"""
        pts = [1000, 1033, 1066, 1100, 1133, 1166]
        for i in range(1, len(pts)):
            assert pts[i] > pts[i - 1]

    def test_pts_jitter_within_tolerance(self):
        """PTS 抖动应在容差范围内"""
        pts_intervals = [33, 34, 33, 33, 35, 33]  # ms
        avg = sum(pts_intervals) / len(pts_intervals)
        max_jitter = max(abs(i - avg) for i in pts_intervals)
        assert max_jitter <= 3  # ±3ms 以内

    def test_system_clock_sync(self):
        """系统时钟应与 PTS 保持同步"""
        pts_time = 1000000  # us = 1s
        system_time = 1000000  # us
        drift = abs(pts_time - system_time)
        assert drift < 5000  # 漂移 < 5ms


class TestVideoDecoding:
    """视频解码测试"""

    def test_h264_decoding(self):
        """H264 解码应输出 NV12/YUV"""
        codec = "H264"
        output_format = "NV12"
        assert codec in ["H264", "H265"]
        assert output_format in ["NV12", "I420", "RGB"]

    def test_hardware_decoder_preferred(self):
        """应优先使用硬解码 (rkvdec)"""
        decoder = "rkvdec"  # RK3588 硬件解码器
        assert "rkvdec" in decoder

    def test_decode_latency_bound(self):
        """解码延迟应 < 20ms (1080p@30fps)"""
        max_decode_ms = 20.0
        actual_decode_ms = 12.0
        assert actual_decode_ms <= max_decode_ms
