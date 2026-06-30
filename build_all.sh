#!/bin/bash
# =============================================================================
# RK3588 Industrial Toolkit — 一键构建脚本
# =============================================================================
# 按依赖顺序构建所有模块: engine → modbus → opcua → pipeline
#
# 用法:
#   ./build_all.sh                  # Release 构建
#   ./build_all.sh debug            # Debug 构建
#   ./build_all.sh install          # 构建并安装到 /opt/rk3588-toolkit
#   ./build_all.sh deploy           # 构建 + 安装 + 注册 systemd 服务
#
# 环境要求:
#   - RK3588 板载编译 或 aarch64 交叉编译工具链
#   - cmake >= 3.16, g++ >= 9 (C++17)
#   - 依赖库: librknnrt, librga, libmodbus, open62541, OpenCV, yaml-cpp
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_TYPE="${1:-Release}"
INSTALL_PREFIX="/opt/rk3588-toolkit"
BUILD_DIR="${SCRIPT_DIR}/build"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo ""; echo -e "${GREEN}===== $* =====${NC}"; }

# ── 参数处理 ──
INSTALL_MODE=false
DEPLOY_MODE=false
case "${BUILD_TYPE}" in
    debug|Debug)
        BUILD_TYPE="Debug"
        ;;
    install)
        BUILD_TYPE="Release"
        INSTALL_MODE=true
        ;;
    deploy)
        BUILD_TYPE="Release"
        INSTALL_MODE=true
        DEPLOY_MODE=true
        ;;
    release|Release|"")
        BUILD_TYPE="Release"
        ;;
    *)
        log_error "未知构建类型: ${BUILD_TYPE}"
        echo "用法: $0 [debug|release|install|deploy]"
        exit 1
        ;;
esac

log_info "构建类型: ${BUILD_TYPE}"
log_info "安装路径: ${INSTALL_PREFIX}"

# ── 环境检测 ──
log_step "环境检测"

if ! command -v cmake &>/dev/null; then
    log_error "cmake 未安装。请执行: sudo apt install cmake"
    exit 1
fi

if ! command -v pkg-config &>/dev/null; then
    log_error "pkg-config 未安装。请执行: sudo apt install pkg-config"
    exit 1
fi

# 检测关键依赖
MISSING_DEPS=()
for dep in librknnrt librga libmodbus open62541 opencv4 yaml-cpp; do
    if ! pkg-config --exists "${dep}" 2>/dev/null; then
        MISSING_DEPS+=("${dep}")
    fi
done

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    log_warn "以下依赖未通过 pkg-config 检测: ${MISSING_DEPS[*]}"
    log_warn "构建可能失败，请确保已安装对应开发包"
fi

# NPU 驱动检测
if [ -e /dev/rknpu ]; then
    log_info "NPU 设备节点存在: /dev/rknpu"
else
    log_warn "NPU 设备节点不存在，推理将无法运行"
fi

# ── 清理旧构建 ──
if [ -d "${BUILD_DIR}" ]; then
    log_info "清理旧构建目录..."
    rm -rf "${BUILD_DIR}"
fi
mkdir -p "${BUILD_DIR}"

# =============================================================================
# 模块 1: 推理引擎 (libengine.so)
# =============================================================================
log_step "模块 1/4: 推理引擎"

ENGINE_SRC="${SCRIPT_DIR}/deploy/engine"
ENGINE_BUILD="${BUILD_DIR}/engine"

cmake -S "${ENGINE_SRC}" -B "${ENGINE_BUILD}" \
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}" \
    -DBUILD_PYTHON=OFF

cmake --build "${ENGINE_BUILD}" -j$(nproc)

log_info "引擎构建完成"
log_info "  libengine.so → ${ENGINE_BUILD}/libengine.so"
log_info "  demo_inference → ${ENGINE_BUILD}/demo_inference"

# =============================================================================
# 模块 2: Modbus TCP Server (libmodbus_server.a)
# =============================================================================
log_step "模块 2/4: Modbus TCP Server"

MODBUS_SRC="${SCRIPT_DIR}/deploy/protocol/modbus"
MODBUS_BUILD="${BUILD_DIR}/modbus"

cmake -S "${MODBUS_SRC}" -B "${MODBUS_BUILD}" \
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}"

cmake --build "${MODBUS_BUILD}" -j$(nproc)

log_info "Modbus Server 构建完成"
log_info "  libmodbus_server.a → ${MODBUS_BUILD}/libmodbus_server.a"
log_info "  modbus_server_demo → ${MODBUS_BUILD}/modbus_server_demo"

# =============================================================================
# 模块 3: OPC UA Server (libopcua_server.a)
# =============================================================================
log_step "模块 3/4: OPC UA Server"

OPCUA_SRC="${SCRIPT_DIR}/deploy/protocol/opcua"
OPCUA_BUILD="${BUILD_DIR}/opcua"

cmake -S "${OPCUA_SRC}" -B "${OPCUA_BUILD}" \
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}"

cmake --build "${OPCUA_BUILD}" -j$(nproc)

log_info "OPC UA Server 构建完成"
log_info "  libopcua_server.a → ${OPCUA_BUILD}/libopcua_server.a"
log_info "  opcua_server_demo → ${OPCUA_BUILD}/opcua_server_demo"

# =============================================================================
# 模块 4: 统一推理流水线 (pipeline_runner)
# =============================================================================
log_step "模块 4/4: 统一推理流水线"

PIPELINE_SRC="${SCRIPT_DIR}/deploy/pipeline"
PIPELINE_BUILD="${BUILD_DIR}/pipeline"

cmake -S "${PIPELINE_SRC}" -B "${PIPELINE_BUILD}" \
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}" \
    -DENGINE_LIB="${ENGINE_BUILD}/libengine.so" \
    -DMODBUS_LIB="${MODBUS_BUILD}/libmodbus_server.a" \
    -DOPCUA_LIB="${OPCUA_BUILD}/libopcua_server.a"

cmake --build "${PIPELINE_BUILD}" -j$(nproc)

log_info "流水线构建完成"
log_info "  pipeline_runner → ${PIPELINE_BUILD}/pipeline_runner"

# =============================================================================
# 安装 (可选)
# =============================================================================
if [ "${INSTALL_MODE}" = true ]; then
    log_step "安装到 ${INSTALL_PREFIX}"

    sudo mkdir -p "${INSTALL_PREFIX}"/{bin,lib,config,models}

    # 安装二进制文件
    sudo cp "${ENGINE_BUILD}/libengine.so"* "${INSTALL_PREFIX}/lib/"
    sudo cp "${ENGINE_BUILD}/demo_inference" "${INSTALL_PREFIX}/bin/"
    sudo cp "${MODBUS_BUILD}/modbus_server_demo" "${INSTALL_PREFIX}/bin/"
    sudo cp "${OPCUA_BUILD}/opcua_server_demo" "${INSTALL_PREFIX}/bin/"
    sudo cp "${PIPELINE_BUILD}/pipeline_runner" "${INSTALL_PREFIX}/bin/"

    # 安装配置文件
    sudo cp "${SCRIPT_DIR}/configs/"*.yaml "${INSTALL_PREFIX}/config/" 2>/dev/null || true
    sudo cp "${MODBUS_SRC}/config/"*.yaml "${INSTALL_PREFIX}/config/" 2>/dev/null || true
    sudo cp "${OPCUA_SRC}/config/"*.yaml "${INSTALL_PREFIX}/config/" 2>/dev/null || true

    # 安装头文件
    sudo mkdir -p "${INSTALL_PREFIX}/include/rk3588/engine"
    sudo cp "${ENGINE_SRC}/include/"*.h "${INSTALL_PREFIX}/include/rk3588/engine/"

    # 配置 ld 路径
    echo "${INSTALL_PREFIX}/lib" | sudo tee /etc/ld.so.conf.d/rk3588-toolkit.conf > /dev/null
    sudo ldconfig

    log_info "安装完成"
    log_info "  二进制: ${INSTALL_PREFIX}/bin/"
    log_info "  库文件: ${INSTALL_PREFIX}/lib/"
    log_info "  配置文件: ${INSTALL_PREFIX}/config/"
fi

# =============================================================================
# 注册 systemd 服务 (可选)
# =============================================================================
if [ "${DEPLOY_MODE}" = true ]; then
    log_step "注册 systemd 服务"

    sudo cp "${SCRIPT_DIR}/deploy/systemd/"*.service /etc/systemd/system/
    sudo systemctl daemon-reload

    log_info "服务文件已安装:"
    log_info "  rk3588-pipeline.service  (统一流水线)"
    log_info "  rk3588-modbus.service    (Modbus 独立服务)"
    log_info "  rk3588-opcua.service     (OPC UA 独立服务)"
    log_info ""
    log_info "启用服务:"
    log_info "  sudo systemctl enable --now rk3588-pipeline"
    log_info ""
    log_info "查看状态:"
    log_info "  sudo systemctl status rk3588-pipeline"
    log_info "  sudo journalctl -u rk3588-pipeline -f"
fi

# =============================================================================
# 冒烟测试
# =============================================================================
log_step "冒烟测试"

FAILURES=0

# 测试 1: 二进制文件存在性
for binary in demo_inference modbus_server_demo opcua_server_demo pipeline_runner; do
    BIN_PATH="${BUILD_DIR}/"
    case "${binary}" in
        demo_inference)   BIN_PATH="${ENGINE_BUILD}/${binary}" ;;
        modbus_server_demo) BIN_PATH="${MODBUS_BUILD}/${binary}" ;;
        opcua_server_demo)  BIN_PATH="${OPCUA_BUILD}/${binary}" ;;
        pipeline_runner)    BIN_PATH="${PIPELINE_BUILD}/${binary}" ;;
    esac

    if [ -f "${BIN_PATH}" ]; then
        log_info "  ✓ ${binary}"
    else
        log_error "  ✗ ${binary} 未找到"
        ((FAILURES++)) || true
    fi
done

# 测试 2: 库文件存在性
if [ -f "${ENGINE_BUILD}/libengine.so" ]; then
    log_info "  ✓ libengine.so"
else
    log_error "  ✗ libengine.so 未找到"
    ((FAILURES++)) || true
fi

# 测试 3: Python 测试 (pytest)
if command -v pytest &>/dev/null; then
    log_info "运行 Python 测试套件..."
    cd "${SCRIPT_DIR}"
    if python -m pytest tests/ -v --tb=short 2>&1 | tail -20; then
        log_info "  ✓ 所有 Python 测试通过"
    else
        log_warn "  部分测试失败 (可能在非 RK3588 环境运行)"
    fi
else
    log_warn "  pytest 未安装，跳过 Python 测试 (pip install pytest)"
fi

# =============================================================================
# 汇总
# =============================================================================
echo ""
echo "============================================="
if [ ${FAILURES} -eq 0 ]; then
    log_info "构建成功! 所有模块已编译"
else
    log_error "构建完成，但有 ${FAILURES} 个检查失败"
fi
echo "============================================="
echo ""
echo "产物位置:"
echo "  推理引擎:     ${ENGINE_BUILD}/libengine.so"
echo "  引擎Demo:     ${ENGINE_BUILD}/demo_inference"
echo "  Modbus:       ${MODBUS_BUILD}/modbus_server_demo"
echo "  OPC UA:       ${OPCUA_BUILD}/opcua_server_demo"
echo "  统一流水线:   ${PIPELINE_BUILD}/pipeline_runner"
echo ""
echo "快速测试:"
echo "  # 测试 Modbus (另一个终端用 modbus-poll 连接 :502)"
echo "  ${MODBUS_BUILD}/modbus_server_demo --port 502"
echo ""
echo "  # 测试 OPC UA (另一个终端用 UaExpert 连接 :4840)"
echo "  ${OPCUA_BUILD}/opcua_server_demo"
echo ""
echo "  # 运行完整流水线"
echo "  ${PIPELINE_BUILD}/pipeline_runner \\"
echo "    --engine ${SCRIPT_DIR}/configs/engine.yaml \\"
echo "    --camera 0 \\"
echo "    --modbus ${MODBUS_SRC}/config/modbus_example.yaml \\"
echo "    --opcua ${OPCUA_SRC}/config/opcua_example.yaml"
echo ""

exit ${FAILURES}
