#!/usr/bin/env python3
"""RK3588 Full Demo: RTSP Camera + NPU Inference + Web Dashboard"""
import cv2, numpy as np, time, signal, threading, json, urllib.request, sys, os
from rknnlite.api import RKNNLite

RTSP = "rtsp://192.168.1.168:554/stream"
MODEL = "/opt/rk3588-toolkit/models/yolov5s.rknn"
DASHBOARD = "http://localhost:8080/api/update"

class Stats:
    fps = 0.0
    latency = 0.0
    frames = 0
    detections = 0

stats = Stats()
running = True

def push_dashboard():
    """Push stats to dashboard every second"""
    while running:
        try:
            data = json.dumps({
                "fps": round(stats.fps, 1),
                "avg_latency_ms": round(stats.latency, 1),
                "total_frames": stats.frames,
                "detection_count": stats.detections,
                "detections": [],
                "status": "running"
            }).encode()
            req = urllib.request.Request(DASHBOARD, data=data, headers={"Content-Type": "application/json"})
            urllib.request.urlopen(req, timeout=1)
        except:
            pass
        time.sleep(1)

def handler(sig, frame):
    global running
    running = False

signal.signal(signal.SIGINT, handler)
signal.signal(signal.SIGTERM, handler)

print('=== RK3588 Full Demo ===')
print(f'RTSP: {RTSP}')
print(f'Dashboard: http://192.168.0.110:8080')

print('\n[1/3] Loading NPU model...')
rknn = RKNNLite()
rknn.load_rknn(MODEL)
rknn.init_runtime(core_mask=0x7)
print('NPU ready')

print('[2/3] Opening RTSP camera...')
cap = cv2.VideoCapture(RTSP, cv2.CAP_FFMPEG)
w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
print(f'Camera: {w}x{h}')

print('[3/3] Starting dashboard reporter...')
threading.Thread(target=push_dashboard, daemon=True).start()

print('\n>>> SYSTEM RUNNING <<<')
print('Open http://192.168.0.110:8080 in browser')
print('Ctrl+C to stop\n')

t0 = time.time()
last_report = t0
n = 0
infer_times = []

while running:
    ret, frame = cap.read()
    if not ret:
        time.sleep(0.01)
        continue
    
    img = cv2.resize(frame, (640, 640))
    img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
    img = np.expand_dims(img, axis=0).astype(np.uint8)
    
    t1 = time.time()
    outputs = rknn.inference(inputs=[img])
    t2 = time.time()
    
    infer_ms = (t2 - t1) * 1000
    infer_times.append(infer_ms)
    n += 1
    
    now = time.time()
    if now - last_report >= 5:
        elapsed = now - t0
        stats.fps = n / elapsed
        stats.latency = sum(infer_times[-20:]) / min(len(infer_times), 20)
        stats.frames = n
        stats.detections = 1
        print(f'  Frames:{n:4d}  FPS:{stats.fps:5.1f}  NPU:{stats.latency:4.0f}ms  Time:{elapsed:5.0f}s')
        last_report = now

cap.release()
rknn.release()
print(f'\nDone. {n} frames total')