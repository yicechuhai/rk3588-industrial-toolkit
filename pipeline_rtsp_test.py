import cv2, numpy as np, time
from rknnlite.api import RKNNLite

print('Loading NPU...')
rknn = RKNNLite()
rknn.load_rknn('/opt/rk3588-toolkit/models/yolov5s.rknn')
rknn.init_runtime(core_mask=0x7)

print('Opening RTSP...')
cap = cv2.VideoCapture('rtsp://192.168.1.168:554/stream', cv2.CAP_FFMPEG)

total_cap = 0
total_resize = 0
total_infer = 0
n = 0
t0 = time.time()

while time.time() - t0 < 10:
    t1 = time.time()
    ret, frame = cap.read()
    t2 = time.time()
    total_cap += (t2 - t1) * 1000
    if not ret:
        continue
    
    img = cv2.resize(frame, (640, 640))
    img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
    img = np.expand_dims(img, axis=0).astype(np.uint8)
    t3 = time.time()
    total_resize += (t3 - t2) * 1000
    
    outputs = rknn.inference(inputs=[img])
    t4 = time.time()
    total_infer += (t4 - t3) * 1000
    n += 1
    
    if n <= 3 or n % 10 == 0:
        print(f'Frame {n}: cap={total_cap/n:.0f}ms resize={total_resize/n:.0f}ms infer={total_infer/n:.0f}ms')

cap.release()
rknn.release()
elapsed = time.time() - t0
print(f'Done: {n} frames in {elapsed:.1f}s')
print(f'Avg capture: {total_cap/n:.0f}ms')
print(f'Avg resize: {total_resize/n:.0f}ms')
print(f'Avg infer: {total_infer/n:.0f}ms')
print(f'Total per frame: {(total_cap+total_resize+total_infer)/n:.0f}ms')
print(f'Overall FPS: {n/elapsed:.1f}')