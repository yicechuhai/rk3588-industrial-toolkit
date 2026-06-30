#!/bin/bash
# =============================================================================
# RK3588 Model Manager — 模型下载/转换/量化工具
# =============================================================================
# 用法:
#   ./model_manager.sh list                  # 列出可用模型
#   ./model_manager.sh download yolov5s       # 下载 YOLOv5s ONNX
#   ./model_manager.sh convert yolov5s        # 转换 ONNX → RKNN (INT8)
#   ./model_manager.sh convert yolov5s fp16   # 转换 ONNX → RKNN (FP16)
#   ./model_manager.sh all                    # 下载+转换所有推荐模型
#
# 依赖:
#   - rknn-toolkit2 (Python): pip install rknn-toolkit2
#   - wget, python3
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_DIR="${SCRIPT_DIR}/models"
mkdir -p "${MODEL_DIR}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }

# =============================================================================
# 模型目录: 名称 → (ONNX_URL, 输入尺寸, 类别数, 推荐量化)
# =============================================================================
declare -A MODEL_URLS
declare -A MODEL_SIZES
declare -A MODEL_CLASSES
declare -A MODEL_RECOMMENDED

MODEL_URLS[yolov5s]="https://github.com/ultralytics/yolov5/releases/download/v7.0/yolov5s.onnx"
MODEL_SIZES[yolov5s]="640 640"
MODEL_CLASSES[yolov5s]=80
MODEL_RECOMMENDED[yolov5s]="int8"

MODEL_URLS[yolov5n]="https://github.com/ultralytics/yolov5/releases/download/v7.0/yolov5n.onnx"
MODEL_SIZES[yolov5n]="640 640"
MODEL_CLASSES[yolov5n]=80
MODEL_RECOMMENDED[yolov5n]="int8"

MODEL_URLS[yolov8s]="https://github.com/ultralytics/assets/releases/download/v8.2.0/yolov8s.onnx"
MODEL_SIZES[yolov8s]="640 640"
MODEL_CLASSES[yolov8s]=80
MODEL_RECOMMENDED[yolov8s]="int8"

MODEL_URLS[yolov8n]="https://github.com/ultralytics/assets/releases/download/v8.2.0/yolov8n.onnx"
MODEL_SIZES[yolov8n]="640 640"
MODEL_CLASSES[yolov8n]=80
MODEL_RECOMMENDED[yolov8n]="int8"

# =============================================================================
# 列出可用模型
# =============================================================================
cmd_list() {
    echo ""
    echo "可用的预训练模型:"
    echo "────────────────────────────────────────────────────────"
    printf "  %-12s %-10s %-8s %-8s\n" "名称" "输入尺寸" "类别" "推荐量化"
    echo "────────────────────────────────────────────────────────"
    for model in "${!MODEL_URLS[@]}"; do
        local_rknn=""
        [ -f "${MODEL_DIR}/${model}.rknn" ] && local_rknn=" [已有RKNN]"
        printf "  ${GREEN}%-12s${NC} %-10s %-8s %-8s%s\n" \
            "${model}" "${MODEL_SIZES[${model}]}" "${MODEL_CLASSES[${model}]}" \
            "${MODEL_RECOMMENDED[${model}]}" "${local_rknn}"
    done
    echo "────────────────────────────────────────────────────────"
    echo ""
    echo "本地已有模型:"
    ls -lh "${MODEL_DIR}"/*.rknn 2>/dev/null || echo "  (无RKNN模型)"
    ls -lh "${MODEL_DIR}"/*.onnx 2>/dev/null || echo "  (无ONNX模型)"
    echo ""
}

# =============================================================================
# 下载模型
# =============================================================================
cmd_download() {
    local model="${1:-}"
    if [ -z "${model}" ]; then
        log_warn "用法: $0 download <模型名>"
        cmd_list
        exit 1
    fi

    local url="${MODEL_URLS[${model}]:-}"
    if [ -z "${url}" ]; then
        log_warn "未知模型: ${model}"
        echo "可用模型: ${!MODEL_URLS[*]}"
        exit 1
    fi

    local onnx_path="${MODEL_DIR}/${model}.onnx"
    if [ -f "${onnx_path}" ]; then
        log_info "${model}.onnx 已存在，跳过下载"
        return
    fi

    log_info "下载 ${model}.onnx ..."
    log_info "URL: ${url}"

    if command -v wget &>/dev/null; then
        wget -q --show-progress -O "${onnx_path}" "${url}" || {
            log_warn "wget 下载失败，尝试 curl..."
            curl -L -o "${onnx_path}" "${url}"
        }
    else
        curl -L -o "${onnx_path}" "${url}"
    fi

    if [ -f "${onnx_path}" ]; then
        local size=$(du -h "${onnx_path}" | cut -f1)
        log_info "下载完成: ${onnx_path} (${size})"
    else
        log_warn "下载失败"
        exit 1
    fi
}

# =============================================================================
# 转换 ONNX → RKNN
# =============================================================================
cmd_convert() {
    local model="${1:-}"
    local quant="${2:-${MODEL_RECOMMENDED[${model}]:-int8}}"

    if [ -z "${model}" ]; then
        log_warn "用法: $0 convert <模型名> [int8|fp16]"
        cmd_list
        exit 1
    fi

    local onnx_path="${MODEL_DIR}/${model}.onnx"
    if [ ! -f "${onnx_path}" ]; then
        log_warn "${model}.onnx 不存在，请先下载: $0 download ${model}"
        exit 1
    fi

    local rknn_path="${MODEL_DIR}/${model}_${quant}.rknn"
    local input_w=$(echo ${MODEL_SIZES[${model}]} | cut -d' ' -f1)
    local input_h=$(echo ${MODEL_SIZES[${model}]} | cut -d' ' -f2)
    local num_classes=${MODEL_CLASSES[${model}]}

    log_info "转换 ${model}.onnx → ${model}_${quant}.rknn"
    log_info "  输入尺寸: ${input_w}x${input_h}"
    log_info "  类别数:   ${num_classes}"
    log_info "  量化方式: ${quant}"

    # 生成临时转换脚本
    cat > /tmp/rknn_convert.py << PYEOF
import sys
from rknn.api import RKNN

model_name = "${model}"
onnx_path = "${onnx_path}"
rknn_path = "${rknn_path}"
input_size = [${input_w}, ${input_h}]
quant = "${quant}"

print(f"[RKNN] Loading ONNX: {onnx_path}")
rknn = RKNN()

# Load ONNX
ret = rknn.load_onnx(model=onnx_path)
if ret != 0:
    print(f"Failed to load ONNX: {ret}")
    sys.exit(1)

print(f"[RKNN] Building model (quant={quant})...")
# Build RKNN model
ret = rknn.build(
    do_quantization=(quant == "int8"),
    dataset=None,  # Use default calibration
    rknn_batch_size=1,
    target_platform="rk3588",
    mean_values=[[0, 0, 0]],
    std_values=[[255, 255, 255]],
    quantized_dtype="w8a8" if quant == "int8" else "w16a16",
    output_optimize=True,
    optimization_level=3,
)
if ret != 0:
    print(f"Failed to build: {ret}")
    sys.exit(1)

print(f"[RKNN] Exporting to: {rknn_path}")
ret = rknn.export_rknn(rknn_path)
if ret != 0:
    print(f"Failed to export: {ret}")
    sys.exit(1)

print(f"[RKNN] Done! Model: {rknn_path}")
rknn.release()
PYEOF

    log_info "运行 RKNN 转换 (这需要几分钟)..."
    python3 /tmp/rknn_convert.py

    if [ -f "${rknn_path}" ]; then
        local size=$(du -h "${rknn_path}" | cut -f1)
        log_info "转换完成: ${rknn_path} (${size})"

        # 创建默认软链接
        ln -sf "$(basename "${rknn_path}")" "${MODEL_DIR}/${model}.rknn"
        log_info "默认模型: ${model}.rknn → ${model}_${quant}.rknn"
    else
        log_warn "转换失败，请检查 RKNN Toolkit 安装"
        log_warn "  pip install rknn-toolkit2"
        exit 1
    fi

    rm -f /tmp/rknn_convert.py
}

# =============================================================================
# 一键下载+转换所有推荐模型
# =============================================================================
cmd_all() {
    log_info "===== 批量下载+转换所有推荐模型 ====="
    echo ""

    local models=("yolov5s" "yolov5n" "yolov8s" "yolov8n")
    local total=${#models[@]}
    local done=0
    local failed=()

    for model in "${models[@]}"; do
        ((done++))
        echo ""
        log_info "[${done}/${total}] 处理 ${model}..."
        echo ""

        if cmd_download "${model}" 2>/dev/null; then
            if cmd_convert "${model}" "${MODEL_RECOMMENDED[${model}]}" 2>/dev/null; then
                log_info "  ${model} OK"
            else
                failed+=("${model}(convert)")
            fi
        else
            failed+=("${model}(download)")
        fi
    done

    echo ""
    echo "============================================="
    if [ ${#failed[@]} -eq 0 ]; then
        log_info "所有模型处理完成!"
    else
        log_warn "以下模型处理失败: ${failed[*]}"
    fi
    echo "============================================="
    echo ""
    echo "模型目录: ${MODEL_DIR}"
    ls -lh "${MODEL_DIR}"/
}

# =============================================================================
# 主入口
# =============================================================================
case "${1:-list}" in
    list)
        cmd_list
        ;;
    download)
        cmd_download "${2:-}"
        ;;
    convert)
        cmd_convert "${2:-}" "${3:-}"
        ;;
    all)
        cmd_all
        ;;
    help|--help|-h)
        echo "用法: $0 {list|download|convert|all} [模型名] [量化方式]"
        echo ""
        echo "示例:"
        echo "  $0 list                 # 列出可用模型"
        echo "  $0 download yolov5s     # 下载 YOLOv5s ONNX"
        echo "  $0 convert yolov5s fp16 # 转换 YOLOv5s (FP16)"
        echo "  $0 all                  # 一键下载+转换所有模型"
        ;;
    *)
        log_warn "未知命令: $1"
        echo "用法: $0 {list|download|convert|all} [模型名]"
        exit 1
        ;;
esac
