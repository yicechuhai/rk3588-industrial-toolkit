#!/usr/bin/env python3
"""
RK3588 YOLOv5s 实时目标检测管线
RTSP摄像头 → rknn-toolkit-lite2 NPU推理 → YOLOv5解码 → NMS → 可视化

用法:
  python3 rtsp_detector.py                          # 默认参数
  python3 rtsp_detector.py --conf 0.3 --nms 0.45   # 自定义阈值
  python3 rtsp_detector.py --save-frames /tmp/out   # 保存检测帧
"""
import sys, cv2, numpy as np, time, argparse, os
from rknnlite.api import RKNNLite

# ── 默认参数 ──
MODEL_PATH = "/tmp/models/yolov5s_rk3588_v5.rknn"
RTSP_URL = "rtsp://192.168.1.168:554/stream"
IMG_SIZE = 640
CONF_THRES = 0.4
NMS_THRES = 0.5
NPU_CORE_MASK = 0x7  # 三核全开

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
        nc = na_ny_nc // na - 5  # 类别数

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

            # 网格坐标 → 像素坐标
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

    # NMS
    indices = cv2.dnn.NMSBoxes(
        all_boxes.tolist(), all_scores.tolist(), conf_thres, nms_thres
    )

    if len(indices) > 0:
        idx = indices.flatten()
        return all_boxes[idx], all_scores[idx], all_class_ids[idx]
    return [], [], []


def draw_detections(frame, boxes, scores, class_ids, scale_x, scale_y):
    """在帧上绘制检测框"""
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
    args = parser.parse_args()

    # ── 1. 加载 RKNN 模型 ──
    print(f"[1/4] Loading model: {args.model}")
    rknn = RKNNLite()
    ret = rknn.load_rknn(args.model)
    assert ret == 0, f"load_rknn failed: {ret}"
    ret = rknn.init_runtime(core_mask=NPU_CORE_MASK)
    assert ret == 0, f"init_runtime failed: {ret}"
    print("      Model loaded, NPU cores:", bin(NPU_CORE_MASK))

    # ── 2. 预热 ──
    print("[2/4] Warmup...")
    dummy = np.zeros((1, IMG_SIZE, IMG_SIZE, 3), dtype=np.uint8)
    _ = rknn.inference(inputs=[dummy])
    print("      OK")

    # ── 3. 打开摄像头 ──
    print(f"[3/4] Opening RTSP: {args.rtsp}")
    cap = cv2.VideoCapture(args.rtsp, cv2.CAP_FFMPEG)
    cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
    assert cap.isOpened(), "Cannot open RTSP stream"
    ow = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    oh = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    print(f"      Resolution: {ow}x{oh}")

    # ── 4. 实时推理 ──
    print("[4/4] Running detection (Ctrl+C to stop)...")
    fc, t_infer_total, t_decode_total = 0, 0.0, 0.0
    t0 = time.time()
    save_dir = args.save_frames
    if save_dir:
        os.makedirs(save_dir, exist_ok=True)

    try:
        while True:
            ret, frame = cap.read()
            if not ret:
                time.sleep(0.01)
                continue

            # 预处理: resize + BGR→RGB
            inp = cv2.resize(frame, (IMG_SIZE, IMG_SIZE))
            inp = np.expand_dims(inp[:, :, ::-1], axis=0).astype(np.uint8)

            # NPU 推理
            t_infer_start = time.time()
            outputs = rknn.inference(inputs=[inp])
            t_infer_total += time.time() - t_infer_start

            # 解码
            t_decode_start = time.time()
            boxes, scores, class_ids = decode_yolov5(outputs, args.conf, args.nms)
            t_decode_total += time.time() - t_decode_start

            # 可视化
            if not args.no_display:
                sx = ow / IMG_SIZE
                sy = oh / IMG_SIZE
                draw_detections(frame, boxes, scores, class_ids, sx, sy)

            fc += 1

            # 保存帧
            if save_dir and fc % 10 == 0:
                out_path = os.path.join(save_dir, f"frame_{fc:06d}.jpg")
                cv2.imwrite(out_path, frame)

            # 打印统计
            if fc % 25 == 0:
                elapsed = time.time() - t0
                fps = fc / elapsed
                avg_infer = (t_infer_total / fc) * 1000 if fc > 0 else 0
                avg_decode = (t_decode_total / fc) * 1000 if fc > 0 else 0
                print(f"  #{fc:4d} | {len(boxes):2d} det | {fps:5.1f} fps | "
                      f"NPU:{avg_infer:5.1f}ms Decode:{avg_decode:5.1f}ms")
                if boxes is not None and len(boxes) > 0 and not args.no_display:
                    top = CLASSES[class_ids[0]] if class_ids[0] < len(CLASSES) else "?"
                    print(f"         top: {top} {scores[0]:.2f}")

    except KeyboardInterrupt:
        print("\n      Stopped by user")

    # ── 统计 ──
    elapsed = time.time() - t0
    print(f"\n{'='*50}")
    print(f"  Total frames:  {fc}")
    print(f"  Elapsed:       {elapsed:.1f}s")
    print(f"  Avg FPS:       {fc/elapsed:.1f}")
    print(f"  Avg NPU time:  {(t_infer_total/fc*1000):.1f}ms" if fc > 0 else "  N/A")
    print(f"  Avg Decode:    {(t_decode_total/fc*1000):.1f}ms" if fc > 0 else "  N/A")
    print(f"{'='*50}")

    rknn.release()
    cap.release()

if __name__ == "__main__":
    main()
