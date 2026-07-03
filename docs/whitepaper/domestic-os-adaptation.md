# 国产 OS 适配技术白皮书

> **版本**: v1.0 | **日期**: 2024-06  
> **主题**: 银河麒麟 V10 / 统信 UOS / openEuler 全栈适配方案

---

## 摘要

在"信创替代"政策推动下，工业企业面临在国产操作系统上部署 AI+实时控制系统的紧迫需求。本白皮书阐述 RK3588-OpenLab 在银河麒麟 V10、统信 UOS 20/1050、openEuler 22.03 三大国产 OS 上的适配方案、实测结论和迁移指南。

**核心结论**: 通过 RK3588-OpenLab 的 OS 兼容层（os-compat-layer），可在 **3 个工作日内**完成从 Ubuntu 到国产 OS 的全栈迁移和 NeoCertify 认证。

---

## 1. 国产 OS 生态概况

### 1.1 主流国产 OS

| 操作系统 | 上游 | 包管理 | 桌面环境 | 信创占比 |
|----------|------|--------|----------|----------|
| **银河麒麟 V10** | openEuler → CentOS 系 | apt (DEB) | UKUI 3.0 | ~40% |
| **统信 UOS 20/1050** | Debian 10 → Deepin | apt (DEB) | DDE | ~35% |
| **openEuler 22.03** | 独立 (类 CentOS) | dnf (RPM) | 无 (Server) | ~15% |
| 中科方德 | Debian | apt | 自研 | ~5% |
| 其他 (红旗、新支点等) | 多样 | 多样 | 多样 | ~5% |

### 1.2 共性特征

所有主流国产 OS 都基于 Linux 内核 (aarch64)，与标准 Linux 的差异主要在：

| 维度 | 差异 | 影响 |
|------|------|------|
| 软件源 | 自建仓库，包版本偏旧 | 需从源码编译或使用兼容包 |
| glibc | 偏旧 (麒麟 2.28, UOS 2.28) | 注意 API 兼容性 |
| 内核模块 | 裁剪过，可能缺驱动 | NPU/RGA 驱动需手动加载 |
| 安全策略 | SELinux/AppArmor 可能开启 | 需配置策略或临时关闭 |
| 路径约定 | 略有不同 | 库搜索路径需适配 |

---

## 2. RK3588-OpenLab 适配层设计

### 2.1 架构

```
┌───────────────────────────────────────────────┐
│              RK3588-OpenLab 应用               │
├───────────────────────────────────────────────┤
│              OS 兼容层 (os-compat-layer)       │
│  ┌─────────┐ ┌──────────┐ ┌───────────────┐  │
│  │ 麒麟适配 │ │ UOS 适配  │ │ openEuler 适配 │  │
│  │ Adapter │ │ Adapter  │ │ Adapter        │  │
│  └────┬────┘ └────┬─────┘ └───────┬───────┘  │
│       └───────────┼───────────────┘           │
│            ┌──────┴──────┐                    │
│            │ 统一检测接口  │                    │
│            │ CompatChecker│                    │
│            └──────┬──────┘                    │
│            ┌──────┴──────┐                    │
│            │ NeoCertify   │                    │
│            │ 认证运行器    │                    │
│            └─────────────┘                    │
├───────────────────────────────────────────────┤
│         国产 OS (麒麟 / UOS / openEuler)       │
└───────────────────────────────────────────────┘
```

### 2.2 核心组件

| 组件 | 功能 | 文件 |
|------|------|------|
| `one_click_install.sh` | 一键安装 (自动检测 OS) | middleware/os-compat-layer/ |
| `compat_checker.py` | 全自动化兼容性检测 | middleware/os-compat-layer/ |
| `kylinos_compat.py` | 麒麟OS 专项适配 | middleware/os-compat-layer/ |
| `neocertify_runner.py` | NeoCertify 认证流程 | middleware/os-compat-layer/ |
| `amp_scheduler.sh` | AMP 异构核调度 | middleware/os-compat-layer/ |

---

## 3. 麒麟OS 适配详情

### 3.1 版本兼容

| 麒麟版本 | 内核 | 状态 | 备注 |
|----------|------|------|------|
| 银河麒麟 V10 SP1 | 4.19.90 | ⚠️ 需升级内核 | 4.19 不支持 RK3588 BSP |
| 银河麒麟 V10 SP2 | 5.10.0-60 | ✅ 完全支持 | 桌面版 |
| 银河麒麟 V10 SP3 | 5.10.0-120 | ✅ 完全支持 | 服务器版 |

### 3.2 关键适配步骤

```bash
# 1. 确认系统版本
cat /etc/kylin-release
uname -r  # 确保 >= 5.10

# 2. 配置 Rockchip NPU 源
sudo bash -c 'cat > /etc/apt/sources.list.d/rk3588.list << EOF
deb [trusted=yes] https://apt.rock-chips.com/kylin/ focal main
EOF'
sudo apt update

# 3. 安装依赖
sudo apt install -y rknn-toolkit-lite2 python3-opencv python3-numpy

# 4. NPU 驱动 (麒麟可能裁剪了内核模块)
sudo modprobe rknpu
echo "rknpu" | sudo tee -a /etc/modules-load.d/rk3588.conf

# 5. OpenCL 路径适配 (麒麟特殊)
sudo ln -sf /usr/lib/aarch64-linux-gnu/libOpenCL.so.1 \
    /usr/lib/libOpenCL.so

# 6. 验证
python3 middleware/os-compat-layer/compat_checker.py
```

### 3.3 麒麟特有坑

| 问题 | 原因 | 解决 |
|------|------|------|
| pip install 超时 | 麒麟 pip 源可能限制 | `pip install -i https://pypi.tuna.tsinghua.edu.cn/simple` |
| firewalld 阻挡 | 麒麟默认用 firewalld | `firewall-cmd --add-port=502/tcp --permanent` |
| SELinux 阻断 | 默认 enforcing | 临时: `setenforce 0`; 长期: 写策略 |
| UKUI 桌面资源占用 | 非 headless 场景 | 建议用服务器版 (无桌面) |

---

## 4. 统信 UOS 适配详情

### 4.1 版本兼容

| UOS 版本 | 基础 | 内核 | 状态 |
|----------|------|------|------|
| UOS 20 专业版 (1030) | Debian 10 | 4.19 | ⚠️ 需升级 |
| UOS 20 专业版 (1050) | Debian 10 | 5.10 | ✅ 完全支持 |
| UOS 20 服务器版 | Debian 10 | 5.10 | ✅ 完全支持 |

### 4.2 适配步骤

```bash
# 1. UOS 识别
cat /etc/os-version  # 或 /etc/deepin-version

# 2. UOS 的 apt 源不同于 Ubuntu
sudo apt edit-sources  # 图形化编辑

# 3. 依赖安装 (包名可能不同于 Ubuntu)
sudo apt install -y \
    python3-dev python3-pip \
    libopencv-dev \
    dkms

# 4. 其余步骤同麒麟OS
sudo bash middleware/os-compat-layer/one_click_install.sh
```

### 4.3 UOS 特有考虑

- UOS 基于 Deepin，DDE 桌面环境资源占用较高，建议 headless 部署
- UOS 的 `apt` 源通常为企业内部源，需管理员配置
- Deepin 的 `deepin-anything` 内核模块可能与 NPU 模块冲突，`lsmod` 检查

---

## 5. openEuler 适配详情

### 5.1 差异

openEuler 使用 **RPM/dnf** 包管理系统，与麒麟/UOS 的 DEB 体系完全不同。

```bash
# 包安装 (dnf)
sudo dnf install -y python3-devel python3-pip opencv-devel

# NPU 运行时 (需从 Rockchip 源码编译)
sudo dnf install -y cmake gcc-c++

# 编译 rknn-toolkit-lite2
git clone https://github.com/airockchip/rknn-toolkit2.git
cd rknn-toolkit2/rknn-toolkit-lite2
sudo python3 setup.py install
```

### 5.2 状态

openEuler 在工业边缘计算中占有率较低，当前适配状态为"基本可用"（核心 AI 推理 + Modbus 正常，OPC UA 需额外测试）。

---

## 6. NeoCertify 认证路径

详见 [neocertify-tutorial.md](../tutorials/neocertify-tutorial.md)。

认证关键点：

| 步骤 | 时间 | 产出 |
|------|------|------|
| 准备材料 (application.json) | 0.5 天 | 申请文档 |
| 兼容性自动化检测 | 1 小时 | 检测报告 |
| 修复不通过项 | 1-2 天 | 补丁/配置 |
| 重新检测 | 1 小时 | 通过报告 |
| 提交审核 | 1 天 | 正式申请 |
| 等待评审 | 5-15 工作日 | 认证证书 |

---

## 7. 迁移检查清单

- [ ] 确认目标 OS 版本和内核版本 (>=5.10)
- [ ] 确认 NPU 驱动可在目标 OS 加载
- [ ] 确认 Python 版本 >=3.7
- [ ] 安装所有依赖包 (包名可能不同)
- [ ] 运行 `compat_checker.py` 检测
- [ ] 修复未通过项
- [ ] 运行单元测试 + 集成测试
- [ ] 运行 NeoCertify 认证流程
- [ ] 配置 systemd 服务
- [ ] 验证开机自启
- [ ] 24 小时稳定性测试
- [ ] 文档归档

---

## 8. 总结

| OS | 适配时间 | 兼容评分 | 推荐场景 |
|-----|----------|---------|----------|
| Ubuntu 22.04 | 0 天 (原生) | 100 | 开发/调试 |
| 麒麟 V10 (SP2+) | 1-2 天 | 95+ | 信创正式部署 |
| UOS 20 (1050+) | 1-2 天 | 92+ | 信创备选 |
| openEuler 22.03 | 3-5 天 | 85+ | 服务器场景 |

RK3588-OpenLab 的 OS 兼容层大幅降低了国产 OS 迁移的技术门槛，使 3 天完成全栈适配成为现实。
