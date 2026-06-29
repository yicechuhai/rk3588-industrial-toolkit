import sys,cv2,numpy as np,time,os
os.environ["RKNN_LOG_LEVEL"]="0"
from rknnlite.api import RKNNLite

# Suppress stderr during inference
import warnings
warnings.filterwarnings("ignore")

MODEL="/tmp/models/y.rknn"
COCO=["person","bicycle","car","motorcycle","airplane","bus","train","truck","boat","traffic light","fire hydrant","stop sign","parking meter","bench","bird","cat","dog","horse","sheep","cow","elephant","bear","zebra","giraffe","backpack","umbrella","handbag","tie","suitcase","frisbee","skis","snowboard","sports ball","kite","baseball bat","baseball glove","skateboard","surfboard","tennis racket","bottle","wine glass","cup","fork","knife","spoon","bowl","banana","apple","sandwich","orange","broccoli","carrot","hot dog","pizza","donut","cake","chair","couch","potted plant","bed","dining table","toilet","tv","laptop","mouse","remote","keyboard","cell phone","microwave","oven","toaster","sink","refrigerator","book","clock","vase","scissors","teddy bear","hair drier","toothbrush"]

def sig(x):return 1/(1+np.exp(-x))
def decode(outs):
  anc=[[[10,13],[16,30],[33,23]],[[30,61],[62,45],[59,119]],[[116,90],[156,198],[373,326]]]
  st=[8,16,32];bs,ss,cs=[],[],[]
  for i,o in enumerate(outs):
    b,ac,h,w=o.shape;na=3;nc=ac//3-5
    o=o.reshape(1,na,5+nc,h,w).transpose(0,1,3,4,2)
    for a in range(na):
      xy=sig(o[0,a,:,:,0:2]);wh=np.exp(o[0,a,:,:,2:4])*np.array(anc[i][a]).reshape(1,1,2)
      obj=sig(o[0,a,:,:,4]);cl=sig(o[0,a,:,:,5:]);conf=obj*np.max(cl,axis=2);cid=np.argmax(cl,axis=2)
      m=conf>0.4
      if not np.any(m):continue
      yv,xv=np.meshgrid(np.arange(h),np.arange(w),indexing="ij")
      cx=(xy[:,:,0]+xv)*st[i];cy=(xy[:,:,1]+yv)*st[i];bw=wh[:,:,0]*st[i];bh=wh[:,:,1]*st[i]
      bs.extend(np.stack([cx[m]-bw[m]/2,cy[m]-bh[m]/2,cx[m]+bw[m]/2,cy[m]+bh[m]/2],axis=1))
      ss.extend(conf[m]);cs.extend(cid[m])
  if not bs:return [],[],[]
  bs=np.array(bs);ss=np.array(ss);cs=np.array(cs,dtype=int)
  idx=cv2.dnn.NMSBoxes(bs.tolist(),ss.tolist(),0.4,0.5)
  if len(idx)>0:idx=idx.flatten();return bs[idx],ss[idx],cs[idx]
  return [],[],[]

sys.stderr = open(os.devnull, 'w')  # Kill all stderr
print("[1/4] Load NPU model...")
rk=RKNNLite();rk.load_rknn(MODEL);rk.init_runtime(core_mask=0x7)
print("[2/4] Warmup...")
for _ in range(3): rk.inference(inputs=[np.zeros((1,640,640,3),dtype=np.uint8)])
print("[3/4] Open camera...")
cap=cv2.VideoCapture("rtsp://192.168.1.168:554/stream",cv2.CAP_FFMPEG)
cap.set(cv2.CAP_PROP_BUFFERSIZE,1)
assert cap.isOpened()
print("[4/4] Run 30 frames...")
fc,t0=0,time.time()
for _ in range(30):
  ret,f=cap.read()
  if not ret:continue
  inp=cv2.resize(f,(640,640));inp=np.expand_dims(inp[:,:,::-1],0).astype(np.uint8)
  outs=rk.inference(inputs=[inp])
  boxes,scores,cids=decode(outs)
  sx,sy=f.shape[1]/640,f.shape[0]/640
  for b,s,c in zip(boxes,scores,cids):
    if c>=len(COCO):continue
    cv2.rectangle(f,(int(b[0]*sx),int(b[1]*sy)),(int(b[2]*sx),int(b[3]*sy)),(0,255,0),2)
    cv2.putText(f,f"{COCO[c]} {s:.2f}",(int(b[0]*sx),int(b[1]*sy)-5),cv2.FONT_HERSHEY_SIMPLEX,0.5,(0,255,0),2)
  fc+=1
  if fc==15: cv2.imwrite("/tmp/detect_demo.jpg",f)

el=time.time()-t0
print(f"DONE: {fc} frames in {el:.1f}s = {fc/el:.1f} fps")
if len(boxes)>0: print(f"Last detection: {COCO[cids[0]]} {scores[0]:.2f}")
print("Sample: /tmp/detect_demo.jpg")
cap.release();rk.release()
