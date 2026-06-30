#!/usr/bin/env python3
import cv2, time, numpy as np, json, urllib.request, os, sys, signal, threading
from collections import deque
from rknnlite.api import RKNNLite

RTSP_URL = os.environ.get("RTSP_URL", "rtsp://192.168.1.168:554/stream")
MODEL_PATH = os.environ.get("MODEL_PATH", "/opt/rk3588-toolkit/models/yolov5s-640-640.rknn")
LABEL_PATH = os.environ.get("LABEL_PATH", "/opt/rk3588-toolkit/models/coco_80_labels_list.txt")
DASHBOARD_URL = os.environ.get("DASHBOARD_URL", "http://localhost:8080")
INPUT_SIZE = 640
CONF_THRESH = 0.5

running = True
stats = {"fps": 0, "avg_latency_ms": 0, "total_frames": 0, "detection_count": 0, "status": "starting"}
latency_window = deque(maxlen=100)

def load_labels(path):
    if os.path.exists(path):
        with open(path) as f:
            return [l.strip() for l in f.readlines()]
    return [f"class_{i}" for i in range(80)]

def post_json(url, data):
    try:
        body = json.dumps(data).encode()
        req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=1)
    except:
        pass

def update_stats():
    global stats
    while running:
        post_json(f"{DASHBOARD_URL}/api/update", stats)
        time.sleep(0.5)

def signal_handler(sig, frame):
    global running
    print(f"Signal {sig}, shutting down...")
    running = False

labels = load_labels(LABEL_PATH)
print(f"Labels: {len(labels)} classes")

print(f"Loading model: {MODEL_PATH}")
rknn = RKNNLite()
rknn.load_rknn(MODEL_PATH)
rknn.init_runtime(core_mask=RKNNLite.NPU_CORE_AUTO)
print("Model ready")

print(f"Opening camera: {RTSP_URL}")
os.environ["OPENCV_FFMPEG_CAPTURE_OPTIONS"] = "rtsp_transport;tcp|buffer_size;1024000"
cap = cv2.VideoCapture(RTSP_URL, cv2.CAP_FFMPEG)
cap.set(cv2.CAP_PROP_BUFFERSIZE, 2)
if not cap.isOpened():
    print("RTSP failed, trying V4L2...")
    cap = cv2.VideoCapture("/dev/video0")
if not cap.isOpened():
    print("FATAL: No camera!")
    sys.exit(1)

frame_w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
frame_h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
print(f"Camera: {frame_w}x{frame_h}")

signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)

stats["status"] = "running"
stats_thread = threading.Thread(target=update_stats, daemon=True)
stats_thread.start()

print("Pipeline running. Ctrl+C to stop.")
t_start = time.time()
frame_count = 0

while running:
    ret, frame = cap.read()
    if not ret or frame is None:
        time.sleep(0.01)
        continue
    
    t0 = time.time()
    rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
    resized = cv2.resize(rgb, (INPUT_SIZE, INPUT_SIZE))
    inp = np.expand_dims(resized, axis=0)
    outputs = rknn.inference(inputs=[inp])
    
    preds = outputs[0].reshape(-1, 85)
    detection_count = 0
    for row in preds:
        obj_conf = float(row[4])
        if obj_conf < CONF_THRESH:
            continue
        class_probs = row[5:]
        class_id = int(np.argmax(class_probs))
        if float(class_probs[class_id]) * obj_conf >= CONF_THRESH:
            detection_count += 1
    
    inf_time = (time.time() - t0) * 1000
    latency_window.append(inf_time)
    frame_count += 1
    
    elapsed = time.time() - t_start
    if frame_count % 10 == 0:
        stats["fps"] = round(frame_count / elapsed, 1)
        stats["avg_latency_ms"] = round(np.mean(latency_window), 1)
        stats["total_frames"] = frame_count
        stats["detection_count"] = detection_count
        stats["status"] = "running"
    
    if frame_count % 50 == 0:
        print(f"Frame {frame_count}: {stats['fps']:.1f} FPS, NPU={inf_time:.1f}ms, det={detection_count}")

stats["status"] = "stopped"
cap.release()
rknn.release()
print(f"Stopped. Processed {frame_count} frames.")

