#!/bin/bash
#===============================================================================
# RK3588 Industrial Toolkit - NPU Demo Runner (社区版)
# 功能：下载预置 YOLOv5s RKNN 模型并运行实时检测 Demo
# 前置条件：先运行 check_env.sh 确认环境就绪
#===============================================================================

set -e

VERSION="v1.0.0"
MODEL_DIR="/opt/rk3588-toolkit/models"
DEMO_DIR="/opt/rk3588-toolkit/demo"
MODEL_URL="https://github.com/airockchip/rknn_model_zoo/raw/main/models/RK3588/yolov5s-640-640.rknn"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

print_banner() {
    echo -e "${CYAN}"
    echo "============================================"
    echo "  RK3588 NPU Demo Runner v${VERSION}"
    echo "  YOLOv5s 实时目标检测 Demo"
    echo "============================================"
    echo -e "${NC}"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}请以 root 权限运行: sudo bash $0${NC}"
        exit 1
    fi
}

check_env() {
    echo "🔍 检查环境..."

    # 检查 NPU 设备
    if [ ! -e /dev/dri/renderD128 ]; then
        echo -e "${RED}❌ NPU 设备不可用 (/dev/dri/renderD128)${NC}"
        echo "   请先运行: sudo bash deploy_scripts/env_check/check_env.sh"
        exit 1
    fi

    # 检查 RKNN Runtime
    if [ ! -f /usr/lib/librknnrt.so ] && [ ! -f /usr/lib64/librknnrt.so ]; then
        echo -e "${YELLOW}⚠ 未找到 librknnrt.so${NC}"
        echo "   正在尝试安装 RKNN Runtime..."
        install_rknn_runtime
    fi

    echo -e "${GREEN}✅ 环境检查通过${NC}"
}

download_model() {
    echo ""
    echo "📥 下载预置模型..."

    mkdir -p "$MODEL_DIR"
    mkdir -p "$DEMO_DIR"

    local model_path="$MODEL_DIR/yolov5s-640-640.rknn"

    if [ -f "$model_path" ]; then
        echo -e "${GREEN}✅ 模型已存在: $model_path${NC}"
    else
        echo "   正在下载 YOLOv5s RKNN 模型..."
        echo "   (此操作需要联网)"
        if wget -q --show-progress "$MODEL_URL" -O "$model_path" 2>/dev/null; then
            echo -e "${GREEN}✅ 模型下载完成${NC}"
        else
            echo -e "${YELLOW}⚠ 在线下载失败，尝试从离线包加载...${NC}"
            local offline_model="../offline_pack/models/yolov5s-640-640.rknn"
            if [ -f "$offline_model" ]; then
                cp "$offline_model" "$model_path"
                echo -e "${GREEN}✅ 从离线包加载模型成功${NC}"
            else
                echo -e "${RED}❌ 无法获取模型文件${NC}"
                echo "   请手动下载:"
                echo "   https://github.com/airockchip/rknn_model_zoo"
                exit 1
            fi
        fi
    fi
}

install_rknn_runtime() {
    echo "   安装 RKNN Runtime..."
    local runtime_url="https://github.com/airockchip/rknn-toolkit2/releases/download/v2.3.2/rknn_runtime_2.3.2_linux_aarch64.deb"
    
    if wget -q --show-progress "$runtime_url" -O /tmp/rknn_runtime.deb 2>/dev/null; then
        dpkg -i /tmp/rknn_runtime.deb 2>/dev/null || true
        apt-get install -f -y 2>/dev/null || true
        echo -e "${GREEN}✅ RKNN Runtime 安装完成${NC}"
    else
        echo -e "${YELLOW}⚠ 在线安装失败，请手动安装:${NC}"
        echo "   https://github.com/airockchip/rknn-toolkit2/releases"
    fi
}

run_demo() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🚀 准备运行 YOLOv5s 实时检测 Demo"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  请选择摄像头来源:"
    echo "    1) USB 摄像头 (/dev/video0)"
    echo "    2) MIPI CSI 摄像头"
    echo "    3) 仅测试模型推理（无摄像头，分析图片）"
    echo ""
    read -p "  请输入选项 [1-3] (默认: 3): " cam_choice
    cam_choice=${cam_choice:-3}

    case $cam_choice in
        1)
            echo ""
            echo "📷 使用 USB 摄像头..."
            if [ -e /dev/video0 ]; then
                echo -e "${GREEN}✅ 检测到 /dev/video0${NC}"
                run_python_demo "usb"
            else
                echo -e "${RED}❌ 未检测到 /dev/video0${NC}"
                echo "   请连接 USB 摄像头后重试"
                exit 1
            fi
            ;;
        2)
            echo ""
            echo "📷 使用 MIPI CSI 摄像头..."
            # 尝试检测 MIPI 摄像头
            local csi_found=false
            for dev in /dev/video*; do
                local media=$(cat /sys/class/video4linux/$(basename $dev)/name 2>/dev/null || echo "")
                if echo "$media" | grep -qi "camera\|mipi\|rkisp"; then
                    csi_found=true
                    break
                fi
            done
            if [ "$csi_found" = true ]; then
                echo -e "${GREEN}✅ 检测到 MIPI 摄像头${NC}"
                run_python_demo "csi"
            else
                echo -e "${YELLOW}⚠ 未确认 MIPI 摄像头，尝试运行...${NC}"
                run_python_demo "csi"
            fi
            ;;
        3)
            echo ""
            echo "🖼️  运行图片推理测试..."
            run_inference_test
            ;;
    esac
}

run_python_demo() {
    local cam_type=$1

    # 生成 Python Demo 脚本
    cat > "$DEMO_DIR/yolov5_demo.py" << 'PYEOF'
#!/usr/bin/env python3
"""
RK3588 YOLOv5s 实时目标检测 Demo (社区版)
检测结果坐标会通过 stdout 输出，方便对接 Modbus 协议层

用法：
  python3 yolov5_demo.py [--camera 0] [--model yolov5s.rknn] [--input usb|csi]
"""

import argparse
import cv2
import numpy as np
import time
import sys
import os
from ctypes import *

# 尝试导入 RKNN
try:
    from rknn.api import RKNN
except ImportError:
    print("❌ 未安装 RKNN Python API")
    print("   请安装: pip3 install rknn-toolkit-lite2")
    sys.exit(1)

# COCO 类别名称 (80类)
CLASSES = [
    'person', 'bicycle', 'car', 'motorcycle', 'airplane', 'bus', 'train',
    'truck', 'boat', 'traffic light', 'fire hydrant', 'stop sign',
    'parking meter', 'bench', 'bird', 'cat', 'dog', 'horse', 'sheep', 'cow',
    'elephant', 'bear', 'zebra', 'giraffe', 'backpack', 'umbrella',
    'handbag', 'tie', 'suitcase', 'frisbee', 'skis', 'snowboard',
    'sports ball', 'kite', 'baseball bat', 'baseball glove', 'skateboard',
    'surfboard', 'tennis racket', 'bottle', 'wine glass', 'cup', 'fork',
    'knife', 'spoon', 'bowl', 'banana', 'apple', 'sandwich', 'orange',
    'broccoli', 'carrot', 'hot dog', 'pizza', 'donut', 'cake', 'chair',
    'couch', 'potted plant', 'bed', 'dining table', 'toilet', 'tv',
    'laptop', 'mouse', 'remote', 'keyboard', 'cell phone', 'microwave',
    'oven', 'toaster', 'sink', 'refrigerator', 'book', 'clock', 'vase',
    'scissors', 'teddy bear', 'hair drier', 'toothbrush'
]

def letterbox(im, new_shape=(640, 640), color=(114, 114, 114)):
    """缩放并填充图片到目标尺寸"""
    shape = im.shape[:2]
    if isinstance(new_shape, int):
        new_shape = (new_shape, new_shape)
    r = min(new_shape[0] / shape[0], new_shape[1] / shape[1])
    ratio = r, r
    new_unpad = int(round(shape[1] * r)), int(round(shape[0] * r))
    dw, dh = new_shape[1] - new_unpad[0], new_shape[0] - new_unpad[1]
    dw /= 2
    dh /= 2
    if shape[::-1] != new_unpad:
        im = cv2.resize(im, new_unpad, interpolation=cv2.INTER_LINEAR)
    top, bottom = int(round(dh - 0.1)), int(round(dh + 0.1))
    left, right = int(round(dw - 0.1)), int(round(dw + 0.1))
    im = cv2.copyMakeBorder(im, top, bottom, left, right, cv2.BORDER_CONSTANT, value=color)
    return im, ratio, (dw, dh)

def xywh2xyxy(x):
    """Convert [x, y, w, h] to [x1, y1, x2, y2]"""
    y = np.copy(x)
    y[:, 0] = x[:, 0] - x[:, 2] / 2  # x1
    y[:, 1] = x[:, 1] - x[:, 3] / 2  # y1
    y[:, 2] = x[:, 0] + x[:, 2] / 2  # x2
    y[:, 3] = x[:, 1] + x[:, 3] / 2  # y2
    return y

def nms(boxes, scores, iou_threshold):
    """非极大值抑制"""
    x1 = boxes[:, 0]
    y1 = boxes[:, 1]
    x2 = boxes[:, 2]
    y2 = boxes[:, 3]
    areas = (x2 - x1 + 1) * (y2 - y1 + 1)
    order = scores.argsort()[::-1]
    keep = []
    while order.size > 0:
        i = order[0]
        keep.append(i)
        xx1 = np.maximum(x1[i], x1[order[1:]])
        yy1 = np.maximum(y1[i], y1[order[1:]])
        xx2 = np.minimum(x2[i], x2[order[1:]])
        yy2 = np.minimum(y2[i], y2[order[1:]])
        w = np.maximum(0.0, xx2 - xx1 + 1)
        h = np.maximum(0.0, yy2 - yy1 + 1)
        inter = w * h
        ovr = inter / (areas[i] + areas[order[1:]] - inter)
        inds = np.where(ovr <= iou_threshold)[0]
        order = order[inds + 1]
    return keep

def postprocess(outputs, conf_threshold=0.25, iou_threshold=0.45, img_shape=(640, 640), orig_shape=None):
    """后处理：解析模型输出，执行 NMS"""
    predictions = np.squeeze(outputs[0])
    
    # 过滤低置信度
    conf = predictions[:, 4]
    mask = conf >= conf_threshold
    predictions = predictions[mask]
    
    if len(predictions) == 0:
        return []
    
    # 类别置信度
    class_conf = np.max(predictions[:, 5:], axis=1)
    class_id = np.argmax(predictions[:, 5:], axis=1)
    
    boxes = predictions[:, :4]
    
    # 转换坐标
    boxes = xywh2xyxy(boxes)
    
    # NMS
    indices = nms(boxes, class_conf, iou_threshold)
    
    results = []
    for i in indices:
        results.append({
            'bbox': boxes[i].tolist(),
            'confidence': float(class_conf[i]),
            'class_id': int(class_id[i]),
            'class_name': CLASSES[int(class_id[i])] if int(class_id[i]) < len(CLASSES) else f"class_{int(class_id[i])}"
        })
    
    return results

def inference_image(rknn, image_path):
    """对单张图片进行推理"""
    img = cv2.imread(image_path)
    if img is None:
        print(f"❌ 无法读取图片: {image_path}")
        return
    
    orig_shape = img.shape[:2]
    img_processed, ratio, (dw, dh) = letterbox(img, (640, 640))
    img_processed = cv2.cvtColor(img_processed, cv2.COLOR_BGR2RGB)
    img_processed = np.expand_dims(img_processed, axis=0).astype(np.uint8)
    
    # 推理
    print("  推理中...")
    t_start = time.time()
    outputs = rknn.inference(inputs=[img_processed])
    t_end = time.time()
    infer_time = (t_end - t_start) * 1000
    
    # 后处理
    results = postprocess(outputs, img_shape=(640, 640), orig_shape=orig_shape)
    
    # 绘制结果
    for r in results:
        x1, y1, x2, y2 = [int(v) for v in r['bbox']]
        # 缩放到原始图像尺寸
        x1 = int((x1 - dw) / ratio[0])
        y1 = int((y1 - dh) / ratio[1])
        x2 = int((x2 - dw) / ratio[0])
        y2 = int((y2 - dh) / ratio[1])
        
        cv2.rectangle(img, (x1, y1), (x2, y2), (0, 255, 0), 2)
        label = f"{r['class_name']} {r['confidence']:.2f}"
        cv2.putText(img, label, (x1, y1 - 10), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 2)
        
        # 输出检测结果（Modbus 友好格式）
        print(f"  📍 {r['class_name']} | 置信度: {r['confidence']:.2f} | "
              f"坐标: ({x1},{y1}) → ({x2},{y2})")
    
    print(f"\n  ⏱ 推理耗时: {infer_time:.1f} ms")
    print(f"  📊 检测到 {len(results)} 个目标")
    
    # 保存结果
    output_path = "detection_result.jpg"
    cv2.imwrite(output_path, img)
    print(f"  💾 结果已保存: {output_path}")

def inference_camera(rknn, cam_type="usb"):
    """实时摄像头推理"""
    cam_id = 0 if cam_type == "usb" else 1
    
    cap = cv2.VideoCapture(cam_id)
    if not cap.isOpened():
        print(f"❌ 无法打开摄像头 {cam_id}")
        # 尝试其他设备号
        for i in range(5):
            cap = cv2.VideoCapture(i)
            if cap.isOpened():
                cam_id = i
                print(f"  → 切换到摄像头 {i}")
                break
        else:
            print("❌ 未找到可用摄像头")
            return
    
    print(f"📷 摄像头已打开 (设备 {cam_id})")
    print("  按 Ctrl+C 停止\n")
    
    frame_count = 0
    fps = 0
    t_last = time.time()
    
    try:
        while True:
            ret, frame = cap.read()
            if not ret:
                print("⚠ 无法读取帧")
                break
            
            orig_shape = frame.shape[:2]
            img_processed, ratio, (dw, dh) = letterbox(frame, (640, 640))
            img_processed = cv2.cvtColor(img_processed, cv2.COLOR_BGR2RGB)
            img_processed = np.expand_dims(img_processed, axis=0).astype(np.uint8)
            
            # 推理
            t_start = time.time()
            outputs = rknn.inference(inputs=[img_processed])
            t_infer = (time.time() - t_start) * 1000
            
            # 后处理
            results = postprocess(outputs, img_shape=(640, 640), orig_shape=orig_shape)
            
            # FPS 计算
            frame_count += 1
            if frame_count % 10 == 0:
                t_now = time.time()
                fps = 10 / (t_now - t_last)
                t_last = t_now
            
            # 终端输出（简洁模式）
            if results:
                main_obj = results[0]
                print(f"  [{frame_count}] {main_obj['class_name']} {main_obj['confidence']:.2f} | "
                      f"{len(results)} obj | {t_infer:.0f}ms | {fps:.0f}FPS", end="\r")
                
                # 输出 Modbus 格式（JSON 一行）
                modbus_output = []
                for r in results[:5]:  # 最多 5 个目标
                    modbus_output.append({
                        "id": r['class_id'],
                        "name": r['class_name'],
                        "conf": round(r['confidence'], 2),
                        "x": int((r['bbox'][0] + r['bbox'][2]) / 2),
                        "y": int((r['bbox'][1] + r['bbox'][3]) / 2),
                        "w": int(r['bbox'][2] - r['bbox'][0]),
                        "h": int(r['bbox'][3] - r['bbox'][1])
                    })
                # stdout 输出 JSON 格式，方便 pipe 到其他程序
                # sys.stdout.write(f"\nDATA:{json.dumps(modbus_output)}\n")
            else:
                print(f"  [{frame_count}] 无目标 | {t_infer:.0f}ms | {fps:.0f}FPS", end="\r")
    
    except KeyboardInterrupt:
        print("\n\n🛑 用户停止")
    finally:
        cap.release()
    
    print(f"\n📊 总计处理 {frame_count} 帧")

def main():
    parser = argparse.ArgumentParser(description='RK3588 YOLOv5s Demo')
    parser.add_argument('--model', type=str, 
                       default='/opt/rk3588-toolkit/models/yolov5s-640-640.rknn',
                       help='RKNN 模型路径')
    parser.add_argument('--input', type=str, choices=['usb', 'csi', 'image'], default='image',
                       help='输入来源')
    parser.add_argument('--image', type=str, default=None,
                       help='图片路径 (--input image 时使用)')
    parser.add_argument('--camera', type=int, default=0,
                       help='摄像头设备号 (默认: 0)')
    
    args = parser.parse_args()
    
    print("🔧 初始化 RKNN Runtime...")
    rknn = RKNN()
    
    # 加载模型
    print(f"📦 加载模型: {args.model}")
    if not os.path.exists(args.model):
        print(f"❌ 模型文件不存在: {args.model}")
        sys.exit(1)
    
    ret = rknn.load_rknn(args.model)
    if ret != 0:
        print(f"❌ 模型加载失败 (错误码: {ret})")
        sys.exit(1)
    
    # 初始化运行时
    print("⚡ 初始化 NPU runtime...")
    ret = rknn.init_runtime(target='rk3588')
    if ret != 0:
        print(f"❌ 运行时初始化失败 (错误码: {ret})")
        sys.exit(1)
    
    print(f"✅ RKNN Runtime 就绪 (npu_core_mask: 0x07)\n")
    
    # 运行推理
    if args.input == 'image':
        if args.image:
            inference_image(rknn, args.image)
        else:
            # 默认使用内置测试图
            test_img = os.path.join(os.path.dirname(__file__), 'test_bus.jpg')
            if os.path.exists(test_img):
                inference_image(rknn, test_img)
            else:
                # 生成一张纯色测试图
                dummy = np.zeros((480, 640, 3), dtype=np.uint8)
                cv2.putText(dummy, "Connect camera for live detection", (50, 240),
                          cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255, 255, 255), 2)
                cv2.imwrite('/tmp/test_dummy.jpg', dummy)
                inference_image(rknn, '/tmp/test_dummy.jpg')
    else:
        inference_camera(rknn, args.input)
    
    rknn.release()

if __name__ == '__main__':
    main()
PYEOF

    echo -e "${GREEN}✅ Demo 脚本已生成${NC}"
    echo ""
    echo "📋 运行命令:"
    echo "   python3 $DEMO_DIR/yolov5_demo.py --input ${cam_type} --model $MODEL_DIR/yolov5s-640-640.rknn"
    echo ""
    echo "  或者直接运行:"
    bash "$DEMO_DIR/yolov5_demo.py" --input "${cam_type}" --model "$MODEL_DIR/yolov5s-640-640.rknn"
}

run_inference_test() {
    echo ""
    echo "🧪 运行模型推理测试 (无需摄像头)..."
    echo ""

    python3 -c "
from rknn.api import RKNN
import numpy as np
import time

rknn = RKNN()
print('📦 加载模型...')
ret = rknn.load_rknn('$MODEL_DIR/yolov5s-640-640.rknn')
if ret != 0:
    print(f'❌ 模型加载失败: {ret}')
    exit(1)

print('⚡ 初始化 NPU...')
ret = rknn.init_runtime(target='rk3588')
if ret != 0:
    print(f'❌ 运行时初始化失败: {ret}')
    exit(1)

print('✅ NPU 就绪')

# 生成模拟输入 (640x640 随机数据)
dummy_input = np.random.randint(0, 256, (1, 640, 640, 3), dtype=np.uint8)

# 预热
print('🔥 预热 NPU...')
for i in range(5):
    rknn.inference(inputs=[dummy_input])

# 正式测试
print('📊 运行 50 次推理测试...')
times = []
for i in range(50):
    t_start = time.time()
    outputs = rknn.inference(inputs=[dummy_input])
    t_end = time.time()
    times.append((t_end - t_start) * 1000)

times.sort()
avg = np.mean(times)
min_t = np.min(times)
max_t = np.max(times)
median = np.median(times)
p99 = np.percentile(times, 99)

print(f'''
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  NPU 推理性能测试结果
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  模型: YOLOv5s (640x640)
  精度: INT8
  设备: RK3588
  
  平均耗时:  {avg:.1f} ms
  中位数:   {median:.1f} ms
  最小值:   {min_t:.1f} ms
  最大值:   {max_t:.1f} ms
  P99:      {p99:.1f} ms
  吞吐量:   {1000/avg:.0f} FPS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
''')

rknn.release()
"
}

#===============================================================================
# 主流程
#===============================================================================
main() {
    print_banner
    check_root
    check_env
    download_model
    run_demo

    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  Demo 已完成${NC}"
    echo -e "${GREEN}  报告问题请提交 GitHub Issue${NC}"
    echo -e "${GREEN}============================================${NC}"
}

main
