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
mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/models"
mkdir -p "$INSTALL_DIR/demo"
mkdir -p "$INSTALL_DIR/configs"
mkdir -p "$INSTALL_DIR/tools"

# 复制核心文件
cp -r deploy_scripts/* "$INSTALL_DIR/" 2>/dev/null || true
cp -r configs/* "$INSTALL_DIR/configs/" 2>/dev/null || true
cp -r deploy/tools/* "$INSTALL_DIR/tools/" 2>/dev/null || true

# 设置执行权限
chmod +x "$INSTALL_DIR/env_check/check_env.sh" 2>/dev/null || true
chmod +x "$INSTALL_DIR/demo/run_yolov5_demo.sh" 2>/dev/null || true

echo ""
echo "✅ 安装完成"
echo ""
echo "快速开始:"
echo "  1. 运行环境检测:"
echo "     sudo bash $INSTALL_DIR/env_check/check_env.sh"
echo ""
echo "  2. 运行 Demo:"
echo "     sudo bash $INSTALL_DIR/demo/run_yolov5_demo.sh"
echo ""
