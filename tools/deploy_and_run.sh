#!/bin/bash
# RK3588 Industrial Toolkit — 一键部署 + YOLO实时检测
# 用法: bash deploy_and_run.sh

set -e
REPO="https://github.com/yicechuhai/rk3588-industrial-toolkit.git"
WORKDIR="/tmp/rk3588-deploy"
MODEL_SRC="/tmp/models/yolov5s_rk3588_v5.rknn"
NEW_LIBRKNN="/tmp/librknnrt_new.so"

echo "========================================="
echo " RK3588 Toolkit 一键部署"
echo "========================================="

# 1. 更新 librknnrt (如果新版存在)
if [ -f "$NEW_LIBRKNN" ]; then
    echo "[1/6] 更新 librknnrt..."
    sudo cp "$NEW_LIBRKNN" /usr/lib/aarch64-linux-gnu/librknnrt.so
    sudo cp "$NEW_LIBRKNN" /usr/lib/librknnrt.so
    sudo ldconfig
    echo "      librknnrt 已更新"
else
    echo "[1/6] librknnrt 保持当前版本"
fi

# 2. 克隆/更新仓库
echo "[2/6] 拉取代码..."
rm -rf "$WORKDIR"
git clone --depth 1 "$REPO" "$WORKDIR"

# 3. 编译引擎 + Python绑定
echo "[3/6] 编译推理引擎 + Python绑定..."
cd "$WORKDIR/deploy/engine"
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release -DBUILD_PYTHON=ON \
    -Dpybind11_DIR=/home/cat/.local/lib/python3.10/site-packages/pybind11/share/cmake/pybind11
make -j4
echo "      引擎编译完成"

# 4. 复制模型
echo "[4/6] 准备模型..."
mkdir -p "$WORKDIR/models"
if [ -f "$MODEL_SRC" ]; then
    cp "$MODEL_SRC" "$WORKDIR/models/"
    echo "      模型已复制"
else
    echo "      警告: 模型文件不存在，请先转换"
fi

# 5. 验证 NPU
echo "[5/6] 验证 NPU..."
python3 -c "
from rknnlite.api import RKNNLite
rk = RKNNLite()
rk.load_rknn('$WORKDIR/models/yolov5s_rk3588_v5.rknn')
rk.init_runtime()
print('      NPU OK')
rk.release()
" 2>&1 | grep -E "NPU|Error" || echo "      NPU 验证跳过"

# 6. 运行检测
echo "[6/6] 启动实时检测..."
echo "========================================="
cd "$WORKDIR"
python3 tools/rtsp_detector.py \
    --model models/yolov5s_rk3588_v5.rknn \
    --rtsp rtsp://192.168.1.168:554/stream \
    --conf 0.4 --nms 0.5

echo ""
echo "部署完成!"
