#!/usr/bin/env python3
import sys, os, time, signal
import cv2, numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'deploy', 'engine', 'python'))
os.environ['LD_LIBRARY_PATH'] = os.path.join(os.path.dirname(__file__), '..', 'deploy', 'engine', 'python')
import rknn_engine

def main():
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument('--engine', default='/opt/rk3588-toolkit/config/engine.yaml')
    p.add_argument('--camera', default='0')
    p.add_argument('--display', action='store_true')
    args = p.parse_args()

    print('[py-pipeline] Init engine...')
    eng = rknn_engine.Engine(args.engine)
    print('[py-pipeline] Loading model...')
    eng.load_model('')
    if not eng.is_ready():
        print('[py-pipeline] Engine not ready'); return 1
    print('[py-pipeline] Engine ready')

    print('[py-pipeline] Open camera...')
    cam_src = int(args.camera) if args.camera.isdigit() else args.camera
    cap = cv2.VideoCapture(cam_src)
    if not cap.isOpened():
        print('[py-pipeline] Cannot open camera'); return 1
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    fps = cap.get(cv2.CAP_PROP_FPS)
    print(f'[py-pipeline] Camera: {w}x{h} @ {fps} FPS')

    running = True
    def handler(sig, frame):
        nonlocal running
        running = False
    signal.signal(signal.SIGINT, handler)
    signal.signal(signal.SIGTERM, handler)

    frame_count = 0
    t0 = time.time()
    last_report = t0
    print('[py-pipeline] Running (Ctrl+C to stop)...')

    # Warmup: discard first few frames
    for _ in range(5):
        cap.read()
    
    while running:
        ret, frame = cap.read()
        if not ret:
            print('[py-pipeline] Frame read failed, retrying...')
            time.sleep(0.1)
            continue
        results = eng.infer(frame, format='BGR888')
        frame_count += 1

        if args.display:
            for det in results:
                x1, y1, x2, y2 = [int(v) for v in det['bbox']]
                cv2.rectangle(frame, (x1, y1), (x2, y2), (0, 255, 0), 2)
                cv2.putText(frame, f"{det['class_name']} {det['confidence']:.2f}",
                           (x1, y1-5), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0,255,0), 1)
            cv2.imshow('RK3588 Pipeline', frame)
            if cv2.waitKey(1) == 27: running = False

        now = time.time()
        if now - last_report >= 5:
            stats = eng.get_stats()
            n = len(results)
            print(f'[py-pipeline] Frames:{frame_count} FPS:{stats["fps"]} Lat:{stats["avg_latency_ms"]}ms Dets:{n}')
            last_report = now

    cap.release()
    cv2.destroyAllWindows()
    stats = eng.get_stats()
    print(f'[py-pipeline] Done. Total:{frame_count} FPS:{stats["fps"]} Lat:{stats["avg_latency_ms"]}ms')
    return 0

if __name__ == '__main__':
    sys.exit(main())