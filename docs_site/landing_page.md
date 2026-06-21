# RK3588 Industrial Toolkit

**RK3588 工业视觉与实时控制中间件** — 让 AI 视觉部署从"3个月调优"压缩到"半天评估 + 1天集成"。

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-RK3588-orange)]()
[![Ubuntu](https://img.shields.io/badge/OS-Ubuntu%2022.04-brightgreen)]()

---

## 🎯 一句话价值主张

**你不用再花 3 个月折腾内核、NPU 驱动和模型部署。我们已经调好了，脚本给你，跑一下就行。**

---

## 📦 你得到什么

| 模块 | 功能 | 交付方式 |
|------|------|---------|
| 🔧 **一键部署** | 环境检测 + 依赖安装 + NPU 状态校验 + Demo 运行 | Shell 脚本，5 分钟出结果 |
| 🧠 **零拷贝推理** | RGA+NPU 流水线，4K 视频→推理→OSD，CPU 占用降低 40% | C++ SDK + Python 绑定 |
| 🏭 **工业协议** | Modbus TCP/RTU + OPC UA，YAML 映射 AI 结果到 PLC | Docker 容器 + 配置模板 |
| ⚡ **实时增强** | PREEMPT_RT 补丁 + CPU 隔离 + 中断亲和力，延迟 < 50μs | 自动化脚本（客户侧编译） |

---

## 🚀 5 分钟快速体验

```bash
git clone https://github.com/yicechuhai/rk3588-industrial-toolkit.git
cd rk3588-industrial-toolkit
sudo bash install.sh
sudo bash /opt/rk3588-toolkit/env_check/check_env.sh
```

---

## 📊 性能数据

| 指标 | 数值 | 说明 |
|------|------|------|
| 中断延迟（空闲） | < 20 μs | cyclictest, p99 |
| 中断延迟（满载） | < 50 μs | stress-ng + iperf3 + NPU推理 |
| YOLOv5s 推理 | 54+ FPS | 640×640 INT8, 3 NPU 核心 |
| ResNet18 推理 | 244 FPS | 224×224 INT8 |
| 视频流水线 CPU 占用 | < 15% | RGA 零拷贝模式 |

---

## 💰 定价

| 版本 | 价格 | 内容 |
|------|------|------|
| **社区版** | 免费 | 环境检测 + Demo 运行 + 基础文档 |
| **标准订阅** | ¥9,800/年 | 全量自动化部署 + NPU 驱动管理 + 调优报告 + 邮件支持 |
| **企业订阅** | ¥29,800/年 | 标准版全部 + 限次远程支持 + 定制适配 |

---

## 🎓 谁在用（或应该用）

- 工业视觉方案商：用 RK3588 做缺陷检测/OCR/定位
- 边缘 AI 工程师：需要在板端部署 YOLO 模型
- PLC 集成商：想把 AI 检测结果接入 PLC/SCADA
- 智能硬件创业者：竞品方案太贵（10万+），自己做又调不出来

---

## 📐 技术承诺

✅ 仅使用 **主线 PREEMPT_RT**，不依赖闭源 AMP  
✅ 只分发 **源码补丁和脚本**，不发布内核二进制  
✅ 所有交付物 **未加密未混淆**，你拥有完全自主权  
✅ 死守 **RK3588 + Ubuntu 22.04 + YOLOv5/v8**

---

## 📖 文档

- [开发指南 (中文)](deploy/docs/zh/development_guide.md)
- [实时调优指南 (中文)](deploy/docs/zh/realtime_tuning_guide.md)
- [FAQ (中文)](deploy/docs/zh/faq.md)
- [Developer Guide (English)](deploy/docs/en/development_guide.md)
- [FAQ (English)](deploy/docs/en/faq.md)

---

## 🤝 社区

- GitHub Issues：[提交问题](https://github.com/yicechuhai/rk3588-industrial-toolkit/issues)
- 讨论：欢迎在 Issues 区分享你的调优经验
- 合作：邮件联系 [GitHub Profile](https://github.com/yicechuhai)

---

## 📄 License

Apache 2.0 © 2026 yicechuhai
