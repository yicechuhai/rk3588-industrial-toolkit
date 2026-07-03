# 麒麟OS 适配教程

> 🎯 在银河麒麟 V10 (KylinOS) 上部署 RK3588-OpenLab 全栈

## 背景

麒麟OS（KylinOS）是国产自主操作系统的代表，基于 openEuler/Linux。RK3588-OpenLab 全面适配麒麟OS V10 桌面版和服务器版，通过 NeoCertify 认证。

## 版本支持

| 麒麟版本 | 架构 | 内核 | 状态 |
|----------|------|------|------|
| 银河麒麟 V10 SP1 (桌面) | aarch64 | 5.10.x | ✅ 完全支持 |
| 银河麒麟 V10 SP2 (桌面) | aarch64 | 5.10.x | ✅ 完全支持 |
| 银河麒麟 V10 SP3 (服务器) | aarch64 | 5.10.x | ✅ 完全支持 |
| 银河麒麟 V10 (飞腾) | aarch64 | 4.19.x | ⚠️ 需额外测试 |

## 1. 系统环境确认

```bash
# 确认 OS
cat /etc/os-release
# 期望: ID=kylin, VERSION_ID="V10"

# 确认架构
uname -m
# 期望: aarch64

# 确认内核
uname -r
# 期望: 5.10.x 或 5.15.x
```

## 2. 一键适配（推荐）

```bash
git clone https://gitee.com/RK3588kaifa/RK3588-OpenLab.git
cd RK3588-OpenLab

# 一键适配脚本
sudo bash middleware/os-compat-layer/one_click_install.sh
```

脚本自动执行：
1. 配置麒麟 apt 源（添加 Rockchip NPU 源）
2. 安装 `rknn-toolkit-lite2`、`numpy`、`opencv-python`
3. 检测并适配系统库路径
4. 配置 `systemd` 服务
5. 运行兼容性自检

## 3. 手动适配

### 3.1 麒麟 apt 源配置

```bash
sudo bash -c 'cat > /etc/apt/sources.list.d/rk3588.list << EOF
deb [trusted=yes] https://apt.rock-chips.com/kylin/ focal main
EOF'

sudo apt update
```

### 3.2 安装依赖

```bash
# 麒麟OS 软件包名称可能有差异
sudo apt install -y \
    python3-dev python3-pip python3-numpy \
    libopencv-dev python3-opencv \
    libopenblas-dev \
    dkms linux-headers-$(uname -r)

# NPU 运行时
sudo apt install -y rknn-toolkit-lite2

# 验证
python3 -c "from rknnlite.api import RKNNLite; print('OK')"
```

### 3.3 NPU 驱动兼容

```bash
# 麒麟OS 内核模块路径
sudo cp /opt/rk3588-toolkit/drivers/rknpu.ko \
    /lib/modules/$(uname -r)/kernel/drivers/npu/
sudo depmod -a
sudo modprobe rknpu

# 验证
lsmod | grep rknpu
dmesg | grep "RKNPU"
```

### 3.4 库路径修复

麒麟OS 的 OpenCL 库路径可能与标准 Ubuntu 不同：

```bash
# 查找
sudo find / -name "libOpenCL.so*" 2>/dev/null

# 创建符号链接 (如果需要)
sudo ln -sf /usr/lib/aarch64-linux-gnu/libOpenCL.so.1 \
    /usr/lib/libOpenCL.so
```

## 4. 兼容性检测

```bash
# 运行专项检测
python3 middleware/os-compat-layer/kylinos_compat.py

# 输出:
# ✅ 内核版本: 5.10.0-60-generic (KylinOS)
# ✅ NPU 驱动: rknpu 1.6.0
# ✅ RGA 驱动: 已加载
# ✅ OpenCL: 可用
# ⚠️ glibc 版本: 2.28 (最低要求 2.27)
# 兼容性评分: 92/100
```

## 5. NeoCertify 认证适配

```bash
# 运行认证检测
python3 middleware/os-compat-layer/neocertify_runner.py
```

详细见 [neocertify-tutorial.md](neocertify-tutorial.md)。

## 6. 已知差异

| 项目 | Ubuntu 22.04 | KylinOS V10 | 解决方案 |
|------|-------------|-------------|----------|
| glibc 版本 | 2.35 | 2.28-2.31 | 兼容，无需处理 |
| pip 源 | pypi.org | 可能需要代理 | `pip install -i https://pypi.tuna.tsinghua.edu.cn/simple` |
| systemd 路径 | `/lib/systemd` | 相同 | 无需处理 |
| 防火墙 | ufw | firewalld | 手动放行端口: `firewall-cmd --add-port=502/tcp` |
| SELinux | 默认关闭 | 可能开启 | `setenforce 0` (临时) 或添加策略 |
| 显示服务 | GDM3 | LightDM | 不影响 headless 部署 |

## 7. 麒麟 ARM 桌面部署 (可选)

如需在麒麟 ARM 桌面环境运行 Dashboard：

```bash
# 安装浏览器
sudo apt install firefox chromium-browser

# 启动 Dashboard
python3 inference/ai-vision/dashboard_server.py --port 8080 --no-browser

# 桌面快捷方式
cat > ~/Desktop/rk3588-dashboard.desktop << EOF
[Desktop Entry]
Name=RK3588 Dashboard
Exec=python3 $PWD/inference/ai-vision/dashboard_server.py
Type=Application
Terminal=true
EOF
chmod +x ~/Desktop/rk3588-dashboard.desktop
```

## 8. 常见问题

**Q: apt update 失败 (网络)?**
```bash
# 使用麒麟官方源或本地 ISO 源
sudo mount /path/to/Kylin-10.iso /mnt
sudo apt-cdrom -m -d=/mnt add
```

**Q: Python 版本太低?**
麒麟 V10 自带 Python 3.7-3.8，最低要求 3.7+，无需升级。

**Q: OpenCL 初始化失败?**
```bash
sudo apt install ocl-icd-libopencl1
clinfo  # 验证
```
