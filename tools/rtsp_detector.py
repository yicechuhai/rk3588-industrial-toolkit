#!/usr/bin/env python3
"""
RK3588 YOLOv5s 实时目标检测管线 (优化版)
RTSP摄像头 → RGA硬件预处理 → rknn-toolkit-lite2 NPU推理 → YOLOv5解码 → NMS → 可视化

特性:
  - RGA 硬件加速预处理 (BGR→RGB + Resize, --rga)
  - 多核 NPU 支持 (--npu-cores 0,1,2)
  - 内存预分配 (避免重复 malloc, 降低延迟抖动)
  - Benchmark 模式 (--benchmark, 详细性能报告)

用法:
  python3 rtsp_detector.py                                    # 默认参数 (CPU预处理)
  python3 rtsp_detector.py --rga --npu-cores 0,1,2           # RGA硬件 + 三核NPU
  python3 rtsp_detector.py --benchmark --save-frames /tmp/out # 性能基准 + 保存帧
  python3 rtsp_detector.py --conf 0.3 --nms 0.45             # 自定义阈值
"""
import sys, cv2, numpy as np, time, argparse, os, json
from rknnlite.api import RKNNLite

# ── RGA 流水线 (硬件加速预处理) ──
try:
    from rga_pipeline import RGAPipeline, create_rga_pipeline, _RGA_AVAIL
except ImportError:
    _RGA_AVAIL = False
    RGAPipeline = None
    create_rga_pipeline = None

# ── 默认参数 ──
MODEL_PATH = "/tmp/models/yolov5s_rk3588_v5.rknn"
RTSP_URL = "rtsp://192.168.1.168:554/stream"
IMG_SIZE = 640
CONF_THRES = 0.4
NMS_THRES = 0.5
NPU_CORE_MASK = 0x7  # 三核全开 (默认)

# COCO 80类
CLASSES = [
    "person","bicycle","car","motorcycle","airplane","bus","train","truck","boat",
    "traffic light","fire hydrant","stop sign","parking meter","bench","bird","cat",
    "dog","horse","sheep","cow","elephant","bear","zebra","giraffe","backpack",
    "umbrella","handbag","tie","suitcase","frisbee","skis","snowboard","sports ball",
    "kite","baseball bat","baseball glove","skateboard","surfboard","tennis racket",
    "bottle","wine glass","cup","fork","knife","spoon","bowl","banana","apple",
    "sandwich","orange","broccoli","carrot","hot dog","pizza","donut","cake",
    "chair","couch","potted plant","bed","dining table","toilet","tv","laptop",
    "mouse","remote","keyboard","cell phone","microwave","oven","toaster","sink",
    "refrigerator","book","clock","vase","scissors","teddy bear","hair drier","toothbrush"
]

# YOLOv5s anchors (640x640)
ANCHORS = [
    [[10,13],[16,30],[33,23]],      # P3/8
    [[30,61],[62,45],[59,119]],     # P4/16
    [[116,90],[156,198],[373,326]]  # P5/32
]
STRIDES = [8, 16, 32]


def parse_npu_cores(core_str):
    """解析 --npu-cores 参数, 返回 core_mask

    Examples:
        "0,1,2" → 0x7 (三核)
        "0"     → 0x1 (单核0)
        "1,2"   → 0x6 (双核1+2)
    """
    cores = [int(c.strip()) for c in core_str.split(",")]
    mask = 0
    for c in cores:
        if not (0 <= c <= 2):
            raise ValueError(f"无效的 NPU 核心号: {c}, 必须是 0, 1, 2")
        mask |= (1 << c)
    return mask


def sigmoid(x):
    return 1 / (1 + np.exp(-x))


def decode_yolov5(outputs, conf_thres, nms_thres):
    """
    解码 YOLOv5 三头输出 → 检测框列表
    返回: boxes(N,4), scores(N), class_ids(N)
    """
    all_boxes, all_scores, all_class_ids = [], [], []

    for i, output in enumerate(outputs):
        batch, na_ny_nc, h, w = output.shape
        na = 3
        nc = na_ny_nc // na - 5

        output = output.reshape(1, na, 5 + nc, h, w)
        output = np.transpose(output, (0, 1, 3, 4, 2))  # (1,3,h,w,85)

        for a in range(na):
            xy = sigmoid(output[0, a, :, :, 0:2])
            wh = np.exp(output[0, a, :, :, 2:4]) * np.array(ANCHORS[i][a]).reshape(1, 1, 2)
            obj = sigmoid(output[0, a, :, :, 4])
            cls = sigmoid(output[0, a, :, :, 5:])

            conf = obj * np.max(cls, axis=2)
            class_id = np.argmax(cls, axis=2)

            mask = conf > conf_thres
            if not np.any(mask):
                continue

            yv, xv = np.meshgrid(np.arange(h), np.arange(w), indexing="ij")
            cx = (xy[:,:,0] + xv) * STRIDES[i]
            cy = (xy[:,:,1] + yv) * STRIDES[i]
            bw = wh[:,:,0] * STRIDES[i]
            bh = wh[:,:,1] * STRIDES[i]

            x1 = cx[mask] - bw[mask] / 2
            y1 = cy[mask] - bh[mask] / 2
            x2 = cx[mask] + bw[mask] / 2
            y2 = cy[mask] + bh[mask] / 2

            all_boxes.extend(np.stack([x1, y1, x2, y2], axis=1))
            all_scores.extend(conf[mask])
            all_class_ids.extend(class_id[mask])

    if not all_boxes:
        return [], [], []

    all_boxes = np.array(all_boxes)
    all_scores = np.array(all_scores)
    all_class_ids = np.array(all_class_ids, dtype=int)

    indices = cv2.dnn.NMSBoxes(
        all_boxes.tolist(), all_scores.tolist(), conf_thres, nms_thres
    )

    if len(indices) > 0:
        idx = indices.flatten()
        return all_boxes[idx], all_scores[idx], all_class_ids[idx]
    return [], [], []


def draw_detections(frame, boxes, scores, class_ids, scale_x, scale_y):
    """在帧上绘制检测框 (CPU 路径)"""
    colors = [
        (0,255,0),(255,0,0),(0,0,255),(255,255,0),(255,0,255),(0,255,255),
        (128,255,0),(255,128,0),(0,128,255),(128,0,255),(255,0,128),(0,255,128)
    ]
    for box, score, cls_id in zip(boxes, scores, class_ids):
        if cls_id >= len(CLASSES):
            continue
        x1 = int(box[0] * scale_x)
        y1 = int(box[1] * scale_y)
        x2 = int(box[2] * scale_x)
        y2 = int(box[3] * scale_y)
        color = colors[cls_id % len(colors)]
        cv2.rectangle(frame, (x1, y1), (x2, y2), color, 2)
        label = f"{CLASSES[cls_id]} {score:.2f}"
        cv2.putText(frame, label, (x1, y1-5),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, color, 2)


def main():
    parser = argparse.ArgumentParser(description="RK3588 YOLOv5s RTSP Detector")
    parser.add_argument("--model", default=MODEL_PATH, help="RKNN model path")
    parser.add_argument("--rtsp", default=RTSP_URL, help="RTSP stream URL")
    parser.add_argument("--conf", type=float, default=CONF_THRES, help="Confidence threshold")
    parser.add_argument("--nms", type=float, default=NMS_THRES, help="NMS threshold")
    parser.add_argument("--save-frames", help="Save detection frames to directory")
    parser.add_argument("--no-display", action="store_true", help="Don't draw boxes (faster)")
    # ── 新增参数 ──
    parser.add_argument("--rga", action="store_true",
                        help="Enable RGA hardware preprocessing (BGR→RGB + resize)")
    parser.add_argument("--npu-cores", default="0,1,2",
                        help="NPU cores to use, e.g. '0,1,2' or '0' (default: 0,1,2)")
    parser.add_argument("--benchmark", action="store_true",
                        help="Detailed performance benchmark mode")
    parser.add_argument("--benchmark-frames", type=int, default=300,
                        help="Frames to run in benchmark mode (default: 300)")
    parser.add_argument("--benchmark-output", default=None,
                        help="Save benchmark report as JSON")
    args = parser.parse_args()

    # ── 解析 NPU 核心配置 ──
    core_mask = parse_npu_cores(args.npu_cores)
    core_names = args.npu_cores

    # ── 1. 加载 RKNN 模型 ──
    print(f"[1/5] Loading model: {args.model}")
    rknn = RKNNLite()
    ret = rknn.load_rknn(args.model)
    assert ret == 0, f"load_rknn failed: {ret}"
    ret = rknn.init_runtime(core_mask=core_mask)
    assert ret == 0, f"init_runtime failed: {ret}"
    print(f"      Model loaded, NPU cores: {core_names} (mask: {bin(core_mask)})")

    # ── 2. RGA 硬件预处理初始化 ──
    if args.rga:
        if _RGA_AVAIL:
            print("[2/5] Initializing RGA hardware pipeline...")
            rga_pipe = create_rga_pipeline(target_size=(IMG_SIZE, IMG_SIZE),
                                            enable_osd=not args.no_display)
            print(f"      RGA pipeline ready (hardware={_RGA_AVAIL})")
        else:
            print("[2/5] WARNING: --rga specified but rga_pipeline not available, falling back to CPU")
            rga_pipe = None
    else:
        rga_pipe = None
        print("[2/5] CPU preprocessing (RGA disabled)")

    # ── 3. 预热 ──
    print("[3/5] Warmup...")
    dummy = np.zeros((1, IMG_SIZE, IMG_SIZE, 3), dtype=np.uint8)
    _ = rknn.inference(inputs=[dummy])
    print("      OK")

    # ── 4. 打开摄像头 ──
    print(f"[4/5] Opening RTSP: {args.rtsp}")
    cap = cv2.VideoCapture(args.rtsp, cv2.CAP_FFMPEG)
    cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
    assert cap.isOpened(), "Cannot open RTSP stream"
    ow = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    oh = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    print(f"      Resolution: {ow}x{oh}")

    # ── 5. 内存预分配 (避免主循环内重复 malloc) ──
    print("[5/5] Pre-allocating buffers...")
    # 预处理缓冲区: 只在 CPU 路径下使用 (RGA 路径自带预分配)
    resize_buf = np.empty((IMG_SIZE, IMG_SIZE, 3), dtype=np.uint8)  # CPU resize 目标
    inp_buf = np.empty((1, IMG_SIZE, IMG_SIZE, 3), dtype=np.uint8)  # NPU 输入 batch
    # decode_yolov5 内部需要的临时数组已由 numpy 管理
    print("      Buffers allocated (resize + NPU input + outputs)")

    # ── Benchmark 模式初始化 ──
    bench_latencies = []      # 每帧端到端延迟 (ms)
    bench_npu_times = []      # NPU 推理耗时 (ms)
    bench_prep_times = []     # 预处理耗时 (ms)
    bench_decode_times = []   # 解码耗时 (ms)

    # ── 实时推理 ──
    header = "BENCHMARK" if args.benchmark else "Running detection"
    print(f"[RUN] {header} (Ctrl+C to stop)...")
    fc, t_infer_total, t_decode_total, t_prep_total = 0, 0.0, 0.0, 0.0
    t0 = time.time()
    save_dir = args.save_frames
    if save_dir:
        os.makedirs(save_dir, exist_ok=True)

    max_frames = args.benchmark_frames if args.benchmark else float("inf")

    try:
        while fc < max_frames:
            ret, frame = cap.read()
            if not ret:
                time.sleep(0.01)
                continue

            # ═══ 预处理: RGA 硬件 或 CPU ═══
            t_prep_start = time.time()

            if rga_pipe is not None:
                # [RGA 硬件路径] BGR→RGB + Resize 一次硬件完成
                rgb_resized, dma_fd = rga_pipe.process(frame)
                inp_buf[0] = rgb_resized  # 直接拷贝到预分配缓冲区
            else:
                # [CPU 路径] 使用预分配缓冲区避免 malloc
                cv2.resize(frame, (IMG_SIZE, IMG_SIZE), dst=resize_buf)
                # BGR→RGB 到预分配的 inp_buf
                inp_buf[0, :, :, 0] = resize_buf[:, :, 2]
                inp_buf[0, :, :, 1] = resize_buf[:, :, 1]
                inp_buf[0, :, :, 2] = resize_buf[:, :, 0]

            t_prep_total += time.time() - t_prep_start

            # ═══ NPU 推理 ═══
            t_infer_start = time.time()
            outputs = rknn.inference(inputs=[inp_buf])
            t_infer_elapsed = time.time() - t_infer_start
            t_infer_total += t_infer_elapsed

            # ═══ 解码 ═══
            t_decode_start = time.time()
            boxes, scores, class_ids = decode_yolov5(outputs, args.conf, args.nms)
            t_decode_elapsed = time.time() - t_decode_start
            t_decode_total += t_decode_elapsed

            # ═══ 可视化 ═══
            if not args.no_display:
                if rga_pipe is not None:
                    # RGA OSD 叠加到 resized RGB 图像上
                    rga_pipe.draw_boxes(rgb_resized, boxes, scores, class_ids,
                                         CLASSES, 1.0, 1.0)
                    # 将带 OSD 的 RGB resized 图像写回原始 frame (用于保存)
                    frame_resized_rgb = cv2.resize(rgb_resized, (ow, oh))
                    frame[:] = frame_resized_rgb[:, :, ::-1]  # RGB→BGR 回写
                else:
                    sx = ow / IMG_SIZE
                    sy = oh / IMG_SIZE
                    draw_detections(frame, boxes, scores, class_ids, sx, sy)

            fc += 1

            # Benchmark: 记录延迟
            if args.benchmark:
                frame_latency = (time.time() - t_prep_start) * 1000  # ms
                bench_latencies.append(frame_latency)
                bench_npu_times.append(t_infer_elapsed * 1000)
                bench_prep_times.append((t_prep_total / fc) * 1000 if fc > 0 else 0)
                bench_decode_times.append(t_decode_elapsed * 1000)

            # 保存帧
            if save_dir and fc % 10 == 0:
                out_path = os.path.join(save_dir, f"frame_{fc:06d}.jpg")
                cv2.imwrite(out_path, frame)

            # 打印统计 (非 benchmark 模式下每 25 帧)
            if not args.benchmark and fc % 25 == 0:
                elapsed = time.time() - t0
                fps = fc / elapsed
                avg_infer = (t_infer_total / fc) * 1000 if fc > 0 else 0
                avg_decode = (t_decode_total / fc) * 1000 if fc > 0 else 0
                avg_prep = (t_prep_total / fc) * 1000 if fc > 0 else 0
                print(f"  #{fc:4d} | {len(boxes):2d} det | {fps:5.1f} fps | "
                      f"Prep:{avg_prep:4.1f}ms NPU:{avg_infer:5.1f}ms Decode:{avg_decode:5.1f}ms")
                if boxes is not None and len(boxes) > 0 and not args.no_display:
                    top_idx = 0
                    if class_ids[top_idx] < len(CLASSES):
                        print(f"         top: {CLASSES[class_ids[top_idx]]} {scores[top_idx]:.2f}")

    except KeyboardInterrupt:
        print("\n      Stopped by user")

    # ── 统计 ──
    elapsed = time.time() - t0
    avg_fps = fc / elapsed if fc > 0 else 0
    avg_infer_ms = (t_infer_total / fc * 1000) if fc > 0 else 0
    avg_decode_ms = (t_decode_total / fc * 1000) if fc > 0 else 0
    avg_prep_ms = (t_prep_total / fc * 1000) if fc > 0 else 0

    print(f"\n{'='*60}")
    print(f"  Total frames:    {fc}")
    print(f"  Elapsed:         {elapsed:.1f}s")
    print(f"  Avg FPS:         {avg_fps:.1f}")
    print(f"  Avg Prep time:   {avg_prep_ms:.1f}ms")
    print(f"  Avg NPU time:    {avg_infer_ms:.1f}ms")
    print(f"  Avg Decode time: {avg_decode_ms:.1f}ms")
    print(f"  RGA Preprocess:  {'ON' if rga_pipe else 'OFF'}")
    print(f"  NPU Cores:       {core_names}")
    print(f"{'='*60}")

    # ── Benchmark 详细报告 ──
    if args.benchmark and len(bench_latencies) > 0:
        latencies = np.array(bench_latencies)
        npu_times = np.array(bench_npu_times)
        decode_times = np.array(bench_decode_times)

        # 丢弃预热帧 (前 10% 或至少 10 帧)
        warmup = max(10, int(len(latencies) * 0.1))
        latencies_stable = latencies[warmup:]
        npu_stable = npu_times[warmup:]
        decode_stable = decode_times[warmup:]

        report = {
            "config": {
                "model": args.model,
                "rtsp": args.rtsp,
                "img_size": IMG_SIZE,
                "conf_thres": args.conf,
                "nms_thres": args.nms,
                "rga_enabled": rga_pipe is not None,
                "npu_cores": core_names,
                "npu_core_mask": core_mask,
                "total_frames": fc,
                "stable_frames": len(latencies_stable),
            },
            "overall": {
                "total_time_s": round(elapsed, 2),
                "avg_fps": round(avg_fps, 2),
            },
            "latency_ms": {
                "mean": round(float(np.mean(latencies_stable)), 2),
                "median": round(float(np.median(latencies_stable)), 2),
                "p95": round(float(np.percentile(latencies_stable, 95)), 2),
                "p99": round(float(np.percentile(latencies_stable, 99)), 2),
                "min": round(float(np.min(latencies_stable)), 2),
                "max": round(float(np.max(latencies_stable)), 2),
                "std": round(float(np.std(latencies_stable)), 2),
            },
            "npu_ms": {
                "mean": round(float(np.mean(npu_stable)), 2),
                "median": round(float(np.median(npu_stable)), 2),
                "p95": round(float(np.percentile(npu_stable, 95)), 2),
            },
            "decode_ms": {
                "mean": round(float(np.mean(decode_stable)), 2),
                "median": round(float(np.median(decode_stable)), 2),
            },
        }

        print(f"\n{'='*60}")
        print("  BENCHMARK REPORT")
        print(f"{'='*60}")
        print(f"  FPS:           {report['overall']['avg_fps']:.1f}")
        print(f"  Latency (mean): {report['latency_ms']['mean']:.1f}ms")
        print(f"  Latency (P95):  {report['latency_ms']['p95']:.1f}ms")
        print(f"  Latency (P99):  {report['latency_ms']['p99']:.1f}ms")
        print(f"  NPU (mean):     {report['npu_ms']['mean']:.1f}ms")
        print(f"  Decode (mean):  {report['decode_ms']['mean']:.1f}ms")
        print(f"  Stable frames:  {report['config']['stable_frames']}")
        print(f"{'='*60}")

        # 保存 JSON 报告
        output_path = args.benchmark_output
        if output_path is None:
            ts = time.strftime("%Y%m%d_%H%M%S")
            output_path = f"/tmp/benchmark_{ts}.json"
        with open(output_path, "w") as f:
            json.dump(report, f, indent=2)
        print(f"  Report saved: {output_path}")

    # ── 清理 ──
    if rga_pipe is not None:
        rga_pipe.release()
    rknn.release()
    cap.release()


if __name__ == "__main__":
    main()
