import cv2, numpy as np, time, sys, os
frame = np.random.randint(0, 255, (480, 640, 3), dtype=np.uint8)
sys.path.insert(0, os.path.expanduser('~/rk3588-toolkit/deploy/engine/python'))
os.environ['LD_LIBRARY_PATH'] = os.path.expanduser('~/rk3588-toolkit/deploy/engine/python')
import rknn_engine
eng = rknn_engine.Engine('/opt/rk3588-toolkit/config/engine.yaml')
eng.load_model('')
print('Ready:', eng.is_ready())
print('Warmup inference...')
results = eng.infer(frame, format='BGR888')
print('Warmup done')
t0 = time.time()
for i in range(5):
    results = eng.infer(frame, format='BGR888')
t1 = time.time()
stats = eng.get_stats()
fps = stats["fps"]
lat = stats["avg_latency_ms"]
n = len(results)
print(f'5 frames in {t1-t0:.2f}s, FPS={fps}, Lat={lat}ms, Dets={n}')