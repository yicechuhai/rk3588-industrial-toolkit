#!/bin/bash
#===============================================================================
# RK3588 Industrial Toolkit - 根级安装脚本
# 使用: bash install.sh
#===============================================================================

set -e

echo "============================================"
echo "  RK3588 Industrial Toolkit 安装脚本"
echo "============================================"
echo ""

# 检查是否为 RK3588
ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ]; then
    echo "⚠ 当前架构: $ARCH"
    echo "  此工具链为 RK3588 (ARM64) 设计"
    echo "  安装脚本将仅复制文件，不执行板级检测"
    echo ""
fi

INSTALL_DIR="/opt/rk3588-toolkit"

echo "📁 安装到: $INSTALL_DIR"

# 备份旧版本
if [ -d "$INSTALL_DIR" ]; then
    BACKUP_DIR="${INSTALL_DIR}.bak.$(date +%Y%m%d_%H%M%S)"
    echo "📦 备份旧版本到: $BACKUP_DIR"
    mv "$INSTALL_DIR" "$BACKUP_DIR"
fi

mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/models"
mkdir -p "$INSTALL_DIR/demo"
mkdir -p "$INSTALL_DIR/configs"
mkdir -p "$INSTALL_DIR/tools"
mkdir -p "$INSTALL_DIR/logs"

# 复制核心文件
cp -r deploy_scripts/env_check "$INSTALL_DIR/env_check" 2>/dev/null || true
cp -r deploy_scripts/demo/* "$INSTALL_DIR/demo/" 2>/dev/null || true
cp -r deploy_scripts/offline_pack "$INSTALL_DIR/offline_pack" 2>/dev/null || true
cp -r configs/* "$INSTALL_DIR/configs/" 2>/dev/null || true
cp -r tools/diagnose/* "$INSTALL_DIR/tools/" 2>/dev/null || true
cp -r tools/benchmark/* "$INSTALL_DIR/tools/" 2>/dev/null || true
cp -r deploy/realtime "$INSTALL_DIR/realtime" 2>/dev/null || true
cp -r deploy/protocol "$INSTALL_DIR/protocol" 2>/dev/null || true
cp -r deploy/engine "$INSTALL_DIR/engine" 2>/dev/null || true

# 设置执行权限
find "$INSTALL_DIR" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true

# 创建软链接
ln -sf "$INSTALL_DIR/tools/diagnose.sh" /usr/local/bin/rk3588-diagnose 2>/dev/null || true
ln -sf "$INSTALL_DIR/tools/benchmark.sh" /usr/local/bin/rk3588-bench 2>/dev/null || true

# 添加到 PATH
if ! grep -q "$INSTALL_DIR/tools" /etc/profile.d/rk3588-toolkit.sh 2>/dev/null; then
    echo "export PATH=\$PATH:$INSTALL_DIR/tools" > /etc/profile.d/rk3588-toolkit.sh
fi

echo ""
echo "✅ 安装完成"
echo ""
echo "┌───────────────────────────────────────────┐"
echo "│  RK3588 Industrial Toolkit 已就绪         │"
echo "├───────────────────────────────────────────┤"
echo "│  安装目录: $INSTALL_DIR"
echo "│                                           │"
echo "│  环境检测:                                │"
echo "│    sudo bash $INSTALL_DIR/env_check/check_env.sh"
echo "│                                           │"
echo "│  运行 Demo:                               │"
echo "│    sudo bash $INSTALL_DIR/demo/run_yolov5_demo.sh"
echo "│                                           │"
echo "│  故障诊断:                                │"
echo "│    rk3588-diagnose                        │"
echo "│                                           │"
echo "│  性能基准:                                │"
echo "│    rk3588-bench                           │"
echo "└───────────────────────────────────────────┘"
echo ""
echo "📋 实时性优化:"
echo "    bash $INSTALL_DIR/realtime/patch_kernel.sh"
echo ""
echo "📋 Modbus 集成:"
echo "    配置文件: $INSTALL_DIR/configs/yaml_templates/modbus_mapping.yaml"

