#!/bin/bash
#===============================================================================
# RK3588 Industrial Toolkit - Web 配置面板 (TUI)
# 使用 whiptail/dialog 引导用户配置推理引擎，生成 engine.yaml
# 依赖: whiptail (apt install whiptail) 或 dialog
# 使用: sudo bash web_config.sh [--output /path/to/engine.yaml]
#===============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT_FILE="${REPO_ROOT}/configs/engine.yaml"
BACKTITLE="RK3588 推理引擎配置向导"
TITLE_HEIGHT=8
MENU_HEIGHT=20
DIALOG_WIDTH=72

# ── 颜色 ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── 检测可用 TUI 工具 ────────────────────────────────────────────────────
TUI=""
detect_tui() {
    if command -v whiptail > /dev/null 2>&1; then
        TUI="whiptail"
    elif command -v dialog > /dev/null 2>&1; then
        TUI="dialog"
    fi
}

# ── 封装 msgbox / inputbox / menu 调用，兼容 whiptail 和 dialog ──────────
msgbox() {
    local title="$1" msg="$2" h="$3" w="$4"
    h="${h:-8}" w="${w:-$DIALOG_WIDTH}"
    if [ "$TUI" = "dialog" ]; then
        dialog --backtitle "$BACKTITLE" --title "$title" --msgbox "$msg" "$h" "$w"
    else
        whiptail --backtitle "$BACKTITLE" --title "$title" --msgbox "$msg" "$h" "$w"
    fi
}

inputbox() {
    local title="$1" prompt="$2" default="$3" h="$4" w="$5"
    h="${h:-8}" w="${w:-$DIALOG_WIDTH}"
    if [ "$TUI" = "dialog" ]; then
        dialog --backtitle "$BACKTITLE" --title "$title" --inputbox "$prompt" "$h" "$w" "$default" 2>&1 1>/dev/tty
    else
        whiptail --backtitle "$BACKTITLE" --title "$title" --inputbox "$prompt" "$h" "$w" "$default" 3>&1 1>&2 2>&3
    fi
}

menu_select() {
    local title="$1" prompt="$2" h="$3" w="$4" mh="$5"
    shift 5
    h="${h:-$MENU_HEIGHT}" w="${w:-$DIALOG_WIDTH}" mh="${mh:-${TITLE_HEIGHT}}"
    if [ "$TUI" = "dialog" ]; then
        dialog --backtitle "$BACKTITLE" --title "$title" --menu "$prompt" "$h" "$w" "$mh" "$@" 2>&1 1>/dev/tty
    else
        whiptail --backtitle "$BACKTITLE" --title "$title" --menu "$prompt" "$h" "$w" "$mh" "$@" 3>&1 1>&2 2>&3
    fi
}

radiolist_select() {
    local title="$1" prompt="$2" h="$3" w="$4" lh="$5"
    shift 5
    h="${h:-$MENU_HEIGHT}" w="${w:-$DIALOG_WIDTH}" lh="${lh:-12}"
    if [ "$TUI" = "dialog" ]; then
        dialog --backtitle "$BACKTITLE" --title "$title" --radiolist "$prompt" "$h" "$w" "$lh" "$@" 2>&1 1>/dev/tty
    else
        whiptail --backtitle "$BACKTITLE" --title "$title" --radiolist "$prompt" "$h" "$w" "$lh" "$@" 3>&1 1>&2 2>&3
    fi
}

# ── 漂亮打印 ──────────────────────────────────────────────────────────────
print_header() {
    echo ""
    echo -e "${CYAN}============================================${NC}"
    echo -e "${CYAN}  RK3588 推理引擎配置向导${NC}"
    echo -e "${CYAN}  Engine Configuration Wizard${NC}"
    echo -e "${CYAN}============================================${NC}"
    echo ""
}

# ── 解析命令行参数 ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output|-o)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --help|-h)
            echo "使用: $0 [--output /path/to/engine.yaml]"
            echo ""
            echo "选项:"
            echo "  --output, -o    指定输出文件路径（默认: configs/engine.yaml）"
            echo "  --help, -h      显示此帮助信息"
            exit 0
            ;;
        *)
            echo "未知选项: $1"
            exit 1
            ;;
    esac
done

# ── 校验/设置默认值 ──────────────────────────────────────────────────────
validate_port() {
    local port="$1"
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    fi
    return 1
}

validate_npu_cores() {
    case "$1" in
        1|2|3) return 0 ;;
        *) return 1 ;;
    esac
}

# ── 配置步骤 ──────────────────────────────────────────────────────────────

# 步骤 1: 选择模型
step_model() {
    local choice
    choice=$(menu_select "步骤 1/6 — 选择模型" \
        "请选择要使用的推理模型：" \
        14 72 6 \
        "yolov5s"    "YOLOv5s — 速度与精度平衡（推荐）" \
        "yolov5n"    "YOLOv5n — 极速轻量版" \
        "yolov8s"    "YOLOv8s — 新一代检测模型" \
        "yolov8n"    "YOLOv8n — YOLOv8 轻量版" \
        "custom"     "自定义模型路径" \
        "skip"       "跳过，使用默认配置")

    case "$choice" in
        yolov5s)
            MODEL_PATH="./models/yolov5s.rknn"
            MODEL_NAME="yolov5s"
            NUM_CLASSES=80
            INPUT_W=640; INPUT_H=640
            ;;
        yolov5n)
            MODEL_PATH="./models/yolov5n.rknn"
            MODEL_NAME="yolov5n"
            NUM_CLASSES=80
            INPUT_W=640; INPUT_H=640
            ;;
        yolov8s)
            MODEL_PATH="./models/yolov8s.rknn"
            MODEL_NAME="yolov8s"
            NUM_CLASSES=80
            INPUT_W=640; INPUT_H=640
            ;;
        yolov8n)
            MODEL_PATH="./models/yolov8n.rknn"
            MODEL_NAME="yolov8n"
            NUM_CLASSES=80
            INPUT_W=640; INPUT_H=640
            ;;
        custom)
            local custom_path
            custom_path=$(inputbox "步骤 1/6 — 自定义模型" \
                "请输入 RKNN 模型文件的完整路径：" \
                "./models/yolov5s.rknn")
            [ -z "$custom_path" ] && custom_path="./models/yolov5s.rknn"
            MODEL_PATH="$custom_path"
            MODEL_NAME="custom"

            local classes
            classes=$(inputbox "步骤 1/6 — 类别数" \
                "请输入模型类别数（默认 80）：" \
                "80")
            NUM_CLASSES="${classes:-80}"

            local iw ih
            iw=$(inputbox "步骤 1/6 — 输入宽度" \
                "请输入模型输入宽度（默认 640）：" \
                "640")
            ih=$(inputbox "步骤 1/6 — 输入高度" \
                "请输入模型输入高度（默认 640）：" \
                "640")
            INPUT_W="${iw:-640}"; INPUT_H="${ih:-640}"
            ;;
        skip|"")
            MODEL_PATH="./models/yolov5s.rknn"
            MODEL_NAME="yolov5s"
            NUM_CLASSES=80
            INPUT_W=640; INPUT_H=640
            ;;
    esac
}

# 步骤 2: 配置 NPU 核心
step_npu() {
    local choice
    choice=$(radiolist_select "步骤 2/6 — NPU 核心数" \
        "选择使用的 NPU 核心数量（更多核心 = 更高吞吐，略增功耗）：" \
        14 72 5 \
        "3" "三核心 0x7 — 最高性能（推荐）" "ON" \
        "2" "双核心 0x3 — 平衡功耗"  "OFF" \
        "1" "单核心 0x1 — 最低功耗"  "OFF")

    case "${choice:-3}" in
        1) NPU_CORE_MASK="0x1" ;;
        2) NPU_CORE_MASK="0x3" ;;
        3) NPU_CORE_MASK="0x7" ;;
        *) NPU_CORE_MASK="0x7" ;;
    esac
}

# 步骤 3: 配置置信度阈值
step_thresholds() {
    local conf
    conf=$(inputbox "步骤 3/6 — 置信度阈值" \
        "检测置信度阈值 (0.0 ~ 1.0)，低于此值的检测结果将被过滤：" \
        "0.5")
    CONF_THRESHOLD="${conf:-0.5}"

    local nms
    nms=$(inputbox "步骤 3/6 — NMS 阈值" \
        "NMS (非极大值抑制) 阈值 (0.0 ~ 1.0)，控制重叠框去重力度：" \
        "0.45")
    NMS_THRESHOLD="${nms:-0.45}"
}

# 步骤 4: 配置协议端口
step_protocols() {
    local choices
    choices=$(radiolist_select "步骤 4/6 — 协议输出" \
        "选择启用的工业协议（使用空格键切换）：" \
        14 72 4 \
        "none"   "不启用协议输出"     "ON" \
        "modbus" "Modbus TCP (端口 502)" "OFF" \
        "opcua"  "OPC UA (端口 4840)"  "OFF" \
        "both"   "同时启用 Modbus + OPC UA" "OFF")

    case "${choices:-none}" in
        modbus)
            PROTO_MODBUS="true"
            PROTO_OPCUA="false"
            local mp
            mp=$(inputbox "步骤 4/6 — Modbus 端口" \
                "请输入 Modbus TCP 端口号（默认 502）：" \
                "502")
            MODBUS_PORT="${mp:-502}"
            OPCUA_PORT="4840"
            ;;
        opcua)
            PROTO_MODBUS="false"
            PROTO_OPCUA="true"
            MODBUS_PORT="502"
            local op
            op=$(inputbox "步骤 4/6 — OPC UA 端口" \
                "请输入 OPC UA 端口号（默认 4840）：" \
                "4840")
            OPCUA_PORT="${op:-4840}"
            ;;
        both)
            PROTO_MODBUS="true"
            PROTO_OPCUA="true"

            local mp2
            mp2=$(inputbox "步骤 4/6 — Modbus 端口" \
                "请输入 Modbus TCP 端口号（默认 502）：" \
                "502")
            MODBUS_PORT="${mp2:-502}"

            local op2
            op2=$(inputbox "步骤 4/6 — OPC UA 端口" \
                "请输入 OPC UA 端口号（默认 4840）：" \
                "4840")
            OPCUA_PORT="${op2:-4840}"
            ;;
        none|"")
            PROTO_MODBUS="false"
            PROTO_OPCUA="false"
            MODBUS_PORT="502"
            OPCUA_PORT="4840"
            ;;
    esac
}

# 步骤 5: 选择输入源
step_input() {
    local choice
    choice=$(radiolist_select "步骤 5/6 — 输入源" \
        "选择推理引擎的输入数据源：" \
        14 72 4 \
        "camera"        "USB/MIPI 摄像头（默认）" "ON" \
        "rtsp"          "RTSP 网络流"             "OFF" \
        "file"          "本地视频文件"             "OFF" \
        "test_pattern"  "测试图案（调试用）"        "OFF")

    case "${choice:-camera}" in
        camera)
            INPUT_SOURCE="camera"
            INPUT_DEVICE="/dev/video0"
            INPUT_WIDTH=1920; INPUT_HEIGHT=1080; INPUT_FPS=30
            ;;
        rtsp)
            INPUT_SOURCE="rtsp"
            INPUT_DEVICE=""
            local rtsp_url
            rtsp_url=$(inputbox "步骤 5/6 — RTSP 地址" \
                "请输入 RTSP 流地址：" \
                "rtsp://192.168.1.100:554/stream")
            RTSP_URL="${rtsp_url:-rtsp://192.168.1.100:554/stream}"
            ;;
        file)
            INPUT_SOURCE="file"
            INPUT_DEVICE=""
            local vf
            vf=$(inputbox "步骤 5/6 — 视频文件" \
                "请输入视频文件路径：" \
                "./data/test_video.mp4")
            FILE_PATH="${vf:-./data/test_video.mp4}"
            ;;
        test_pattern)
            INPUT_SOURCE="test_pattern"
            INPUT_DEVICE=""
            ;;
        *)
            INPUT_SOURCE="camera"
            INPUT_DEVICE="/dev/video0"
            ;;
    esac
}

# 步骤 6: 日志与监控
step_logging() {
    local level
    level=$(radiolist_select "步骤 6/6 — 日志级别" \
        "选择日志输出级别：" \
        14 72 4 \
        "info"  "信息级 — 记录关键操作（推荐）" "ON" \
        "debug" "调试级 — 详细日志（开发用）"   "OFF" \
        "warn"  "警告级 — 仅记录警告和错误"    "OFF" \
        "error" "错误级 — 仅记录错误"          "OFF")

    LOG_LEVEL="${level:-info}"

    local stats
    stats=$(inputbox "步骤 6/6 — 统计间隔" \
        "性能统计输出间隔（秒，默认 60）：" \
        "60")
    STATS_INTERVAL="${stats:-60}"
}

# ── 生成 engine.yaml ──────────────────────────────────────────────────────
generate_engine_yaml() {
    local output="$1"

    # 确保输出目录存在
    mkdir -p "$(dirname "$output")"

    cat > "$output" << YAML_EOF
# ============================================================================
# RK3588 推理引擎配置 (由 web_config.sh 生成)
# 生成时间: $(date "+%Y-%m-%d %H:%M:%S")
# ============================================================================

version: "1.0"

model:
  path: "${MODEL_PATH}"
  input_size: [${INPUT_W}, ${INPUT_H}]
  num_classes: ${NUM_CLASSES}
  conf_threshold: ${CONF_THRESHOLD}
  nms_threshold: ${NMS_THRESHOLD}

npu:
  core_mask: ${NPU_CORE_MASK}
  frequency: "auto"
  perf_level: "high"
  dma_buf: true

preprocess:
  mean: [0, 0, 0]
  std: [255, 255, 255]
  letterbox: true
  color_space: "bgr"

postprocess:
  enable_tracking: false
  draw_boxes: true
  save_detections: false
  output_dir: "./output/detections"

input:
  source: "${INPUT_SOURCE}"
YAML_EOF

    # 根据输入源追加对应配置
    case "$INPUT_SOURCE" in
        camera)
            cat >> "$output" << YAML_CAM
  camera:
    device: "${INPUT_DEVICE}"
    width: ${INPUT_WIDTH}
    height: ${INPUT_HEIGHT}
    fps: ${INPUT_FPS}
    pixel_format: "NV12"
YAML_CAM
            ;;
        rtsp)
            cat >> "$output" << YAML_RTSP
  rtsp:
    url: "${RTSP_URL}"
    buffer_size: 4
    reconnect_interval: 3
YAML_RTSP
            ;;
        file)
            cat >> "$output" << YAML_FILE
  file:
    path: "${FILE_PATH}"
    loop: true
YAML_FILE
            ;;
    esac

    cat >> "$output" << YAML_TAIL

protocol:
  modbus:
    enabled: ${PROTO_MODBUS}
    port: ${MODBUS_PORT}
  opcua:
    enabled: ${PROTO_OPCUA}
    endpoint: "opc.tcp://0.0.0.0:${OPCUA_PORT}"

logging:
  level: "${LOG_LEVEL}"
  file: "/var/log/rk3588-toolkit/inference.log"
  max_size_mb: 100
  stats_interval: ${STATS_INTERVAL}

recovery:
  auto_restart: true
  max_restarts: 5
  restart_delay: 3
  watchdog: true
YAML_TAIL
}

# ── 预览配置 ──────────────────────────────────────────────────────────────
preview_config() {
    local summary
    summary="┌─────────────────────────────────────────────┐
│  配置预览                                    │
├─────────────────────────────────────────────┤
│  模型:       ${MODEL_NAME} (${MODEL_PATH})
│  输入尺寸:   ${INPUT_W}×${INPUT_H}
│  类别数:     ${NUM_CLASSES}
│  置信度:     ${CONF_THRESHOLD}
│  NMS:        ${NMS_THRESHOLD}
│  NPU 核心:   ${NPU_CORE_MASK}
│  输入源:     ${INPUT_SOURCE}
│  Modbus:     ${PROTO_MODBUS} (端口 ${MODBUS_PORT})
│  OPC UA:     ${PROTO_OPCUA} (端口 ${OPCUA_PORT})
│  日志级别:   ${LOG_LEVEL}
│  统计间隔:   ${STATS_INTERVAL}s
├─────────────────────────────────────────────┤
│  输出文件:   ${OUTPUT_FILE}
└─────────────────────────────────────────────┘"

    msgbox "配置预览" "$summary" 20 72
}

# ── 主流程 ────────────────────────────────────────────────────────────────
main() {
    detect_tui

    if [ -z "$TUI" ]; then
        # 无 TUI 工具，回退到纯文本交互模式
        print_header
        echo -e "${YELLOW}⚠ 未检测到 whiptail 或 dialog，使用纯文本模式${NC}"
        echo "  安装 TUI 工具以获得更好的体验："
        echo "    sudo apt install -y whiptail"
        echo ""

        # 简化文本模式：使用默认值
        echo "将使用默认配置生成 engine.yaml ..."
        MODEL_PATH="./models/yolov5s.rknn"
        MODEL_NAME="yolov5s"
        NUM_CLASSES=80
        INPUT_W=640; INPUT_H=640
        CONF_THRESHOLD="0.5"
        NMS_THRESHOLD="0.45"
        NPU_CORE_MASK="0x7"
        INPUT_SOURCE="camera"
        INPUT_DEVICE="/dev/video0"
        INPUT_WIDTH=1920; INPUT_HEIGHT=1080; INPUT_FPS=30
        PROTO_MODBUS="false"
        PROTO_OPCUA="false"
        MODBUS_PORT="502"
        OPCUA_PORT="4840"
        LOG_LEVEL="info"
        STATS_INTERVAL="60"
    else
        print_header

        # TUI 欢迎页
        msgbox "欢迎" \
            "欢迎使用 RK3588 推理引擎配置向导！

本向导将引导您完成以下配置：
  1. 选择 AI 模型
  2. 配置 NPU 核心数
  3. 设置检测阈值
  4. 启用工业协议
  5. 选择输入源
  6. 设置日志级别

配置文件将保存到：
  ${OUTPUT_FILE}" \
            16 72

        # 执行各配置步骤
        step_model    || { echo -e "${RED}✗ 用户取消${NC}"; exit 0; }
        step_npu      || { echo -e "${RED}✗ 用户取消${NC}"; exit 0; }
        step_thresholds || { echo -e "${RED}✗ 用户取消${NC}"; exit 0; }
        step_protocols  || { echo -e "${RED}✗ 用户取消${NC}"; exit 0; }
        step_input      || { echo -e "${RED}✗ 用户取消${NC}"; exit 0; }
        step_logging    || { echo -e "${RED}✗ 用户取消${NC}"; exit 0; }

        # 预览
        preview_config
    fi

    # 生成配置文件
    echo ""
    echo -e "${CYAN}────────────────────────────────────────────${NC}"
    echo "  正在生成配置文件 ..."
    generate_engine_yaml "$OUTPUT_FILE"

    echo ""
    echo -e "  ${GREEN}✅ 配置文件已生成${NC}"
    echo "     路径: ${OUTPUT_FILE}"
    echo ""
    echo -e "${CYAN}────────────────────────────────────────────${NC}"
    echo ""

    # 询问是否立即验证
    if [ -n "$TUI" ]; then
        if whiptail --backtitle "$BACKTITLE" --title "配置完成" \
            --yesno "配置文件已生成。是否立即运行环境检测？" 8 60; then
            echo "  正在运行环境检测 ..."
            echo ""
            if [ -f "${REPO_ROOT}/deploy_scripts/env_check/check_env.sh" ]; then
                bash "${REPO_ROOT}/deploy_scripts/env_check/check_env.sh"
            else
                echo -e "  ${YELLOW}⚠ 未找到 check_env.sh，跳过环境检测${NC}"
            fi
        fi
    fi

    echo ""
    echo -e "  下一步："
    echo -e "    ${GREEN}bash ${REPO_ROOT}/install.sh --ai-only${NC}"
    echo "    或手动编辑配置："
    echo -e "    ${GREEN}vim ${OUTPUT_FILE}${NC}"
    echo ""
}

main "$@"
