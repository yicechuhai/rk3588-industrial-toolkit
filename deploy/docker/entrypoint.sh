#!/bin/bash
#===============================================================================
# RK3588 Industrial Toolkit — 容器入口脚本
#
# 职责:
#   1. 检查 NPU 设备 /dev/rknpu
#   2. 检查 RGA 设备
#   3. 依次启动: 推理引擎 → Modbus Server → OPC UA Server
#===============================================================================

set -e

INSTALL_DIR="/opt/rk3588-toolkit"
CONFIG_DIR="${INSTALL_DIR}/configs"
LOG_DIR="${INSTALL_DIR}/logs"

# 环境变量默认值
: "${INFERENCE_PORT:=50051}"
: "${MODBUS_PORT:=502}"
: "${OPCUA_PORT:=4840}"
: "${MODBUS_CONFIG:=${CONFIG_DIR}/modbus_mapping.yaml}"
: "${OPCUA_CONFIG:=${CONFIG_DIR}/opcua_server.yaml}"
: "${GLOBAL_CONFIG:=${CONFIG_DIR}/global_config.yaml}"

#===============================================================================
# 工具函数
#===============================================================================
log_info()  { echo "[$(date '+%H:%M:%S')] [INFO]  $*"; }
log_warn()  { echo "[$(date '+%H:%M:%S')] [WARN]  $*" >&2; }
log_error() { echo "[$(date '+%H:%M:%S')] [ERROR] $*" >&2; }

check_device() {
    local dev=$1 name=$2
    if [ -e "$dev" ]; then
        log_info "${name} 设备已检测到: $dev"
    else
        log_warn "${name} 设备未找到: $dev — 将以软件模式运行"
    fi
}

#===============================================================================
# 1. 硬件检测
#===============================================================================
log_info "============================================"
log_info "  RK3588 Industrial Toolkit — 容器启动"
log_info "============================================"
echo ""

log_info ">> 检测硬件加速设备..."

# NPU 设备: /dev/rknpu (RK3588 标准节点)
check_device "/dev/rknpu" "NPU"

# RGA 设备: /dev/rga
check_device "/dev/rga" "RGA"

# DRM 渲染节点 (NPU 通过 DRM 子系统的 DMA-BUF 与 RGA 交互)
if [ -e "/dev/dri/renderD128" ]; then
    log_info "DRM 渲染节点已检测到: /dev/dri/renderD128"
else
    log_warn "DRM 渲染节点未找到，零拷贝路径可能不可用"
fi

# 检查 NPU 驱动是否加载 (rknn_server 是 RKNN Runtime 的后台代理)
if command -v rknn_server &>/dev/null; then
    rknn_server &
    sleep 1
    log_info "rknn_server 已启动 (NPU 驱动代理)"
else
    log_warn "rknn_server 不可用，NPU 推理可能受限"
fi

echo ""

#===============================================================================
# 2. 启动推理引擎
#===============================================================================
log_info ">> 启动零拷贝推理引擎 (端口 ${INFERENCE_PORT})..."

if [ -f "${INSTALL_DIR}/lib/libengine.so" ]; then
    # 以 PID 1 的子进程方式启动引擎，让 Docker 的 stop 信号能正确传递
    "${INSTALL_DIR}/bin/engine_server" \
        --port "${INFERENCE_PORT}" \
        --config "${GLOBAL_CONFIG}" \
        --log-dir "${LOG_DIR}" &

    ENGINE_PID=$!
    log_info "推理引擎已启动 (PID: ${ENGINE_PID})"

    # 等待引擎就绪
    sleep 2
    if ! kill -0 ${ENGINE_PID} 2>/dev/null; then
        log_error "推理引擎启动失败，退出"
        exit 1
    fi
else
    log_warn "libengine.so 未找到，跳过推理引擎启动"
fi

echo ""

#===============================================================================
# 3. 启动 Modbus TCP Server
#===============================================================================
log_info ">> 启动 Modbus TCP Server (端口 ${MODBUS_PORT})..."

if [ -f "${INSTALL_DIR}/bin/modbus_server" ]; then
    "${INSTALL_DIR}/bin/modbus_server" \
        --port "${MODBUS_PORT}" \
        --config "${MODBUS_CONFIG}" \
        --log-dir "${LOG_DIR}" &

    MODBUS_PID=$!
    log_info "Modbus Server 已启动 (PID: ${MODBUS_PID})"
else
    log_error "modbus_server 未找到"
fi

echo ""

#===============================================================================
# 4. 启动 OPC UA Server
#===============================================================================
log_info ">> 启动 OPC UA Server (端口 ${OPCUA_PORT})..."

if [ -f "${INSTALL_DIR}/bin/opcua_server" ]; then
    "${INSTALL_DIR}/bin/opcua_server" \
        --port "${OPCUA_PORT}" \
        --config "${OPCUA_CONFIG}" \
        --log-dir "${LOG_DIR}" &

    OPCUA_PID=$!
    log_info "OPC UA Server 已启动 (PID: ${OPCUA_PID})"
else
    log_error "opcua_server 未找到"
fi

echo ""

#===============================================================================
# 5. 运行状态汇总
#===============================================================================
log_info "============================================"
log_info "  全部服务已启动"
log_info "============================================"
log_info "  推理引擎:  0.0.0.0:${INFERENCE_PORT}"
log_info "  Modbus:   0.0.0.0:${MODBUS_PORT}"
log_info "  OPC UA:   0.0.0.0:${OPCUA_PORT}"
log_info "  日志目录:  ${LOG_DIR}"
log_info "============================================"

#===============================================================================
# 6. 等待子进程 & 信号转发
#===============================================================================
cleanup() {
    log_info "收到停止信号，正在关闭所有服务..."
    # 按启动的逆序停止
    [ -n "${OPCUA_PID}" ] && kill -TERM ${OPCUA_PID} 2>/dev/null || true
    [ -n "${MODBUS_PID}" ] && kill -TERM ${MODBUS_PID} 2>/dev/null || true
    [ -n "${ENGINE_PID}" ] && kill -TERM ${ENGINE_PID} 2>/dev/null || true
    wait 2>/dev/null
    log_info "所有服务已停止"
    exit 0
}

trap cleanup SIGTERM SIGINT SIGQUIT

# 持续等待任意子进程退出
while true; do
    for pid in ${ENGINE_PID} ${MODBUS_PID} ${OPCUA_PID}; do
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
            log_error "服务 PID $pid 异常退出，正在关闭全部服务..."
            cleanup
        fi
    done
    sleep 5
done
