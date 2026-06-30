import cv2, time
cap=cv2.VideoCapture('rtsp://192.168.1.168:554/stream',cv2.CAP_FFMPEG)
if not cap.isOpened():
    print('FAIL'); exit()
t0=time.time()
n=0
while time.time()-t0<8:
    ret,f=cap.read()
    if ret:
        n+=1
        if n==1: print(f'Frame shape: {f.shape}')
    else:
        time.sleep(0.05)
cap.release()
print(f'{n} frames in {time.time()-t0:.1f}s FPS={n/(time.time()-t0):.1f}')