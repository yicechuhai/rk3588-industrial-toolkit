# RK3588 Industrial Vision & Real-time Control Toolkit

**RK3588 工业视觉与实时控制中间件** — 让 AI 视觉部署从"3个月调优"压缩到"半天评估 + 1天集成"。

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-RK3588-orange)]()
[![Ubuntu](https://img.shields.io/badge/OS-Ubuntu%2022.04-brightgreen)]()

---

## 🎯 一句话

你不用再花 3 个月折腾内核、NPU 驱动和模型部署。脚本给你，跑一下就行。

---

## 📦 项目结构

```
rk3588-industrial-toolkit/
├── deploy_scripts/                  # 一键部署工具 ⭐ 入门从这里开始
│   ├── env_check/check_env.sh       # 环境检测 → 生成 HTML 报告
│   ├── demo/run_yolov5_demo.sh      # YOLOv5s 实时检测 Demo
│   └── offline_pack/                # 离线依赖包
│
├── deploy/                          # 产品核心模块
│   ├── realtime/                    # 实时增强（PREEMPT_RT 补丁）
│   ├── engine/                      # 零拷贝推理引擎（C++/Python SDK）
│   ├── protocol/                    # 工业协议适配（Modbus/OPC UA）
│   ├── docs/                        # 完整文档
│   │   ├── zh/                      #   中文：开发指南 / 调优指南 / FAQ
│   │   └── en/                      #   English docs
│   └── examples/                    # 示例项目
│       ├── yolov5_demo/             #   YOLO 目标检测
│       └── modbus_demo/             #   Modbus 通信
│
├── tools/                           # 诊断与基准测试
│   ├── diagnose/diagnose.sh         # 故障一键诊断
│   └── benchmark/benchmark.sh       # 性能基准测试
│
├── patches/                         # 补丁包
│   ├── preempt_rt/                  # PREEMPT_RT 编译脚本
│   └── npu_driver/                  # NPU 驱动管理
│
├── configs/yaml_templates/          # 配置模板
│   ├── modbus_mapping.yaml          # Modbus 地址映射
│   ├── opcua_server.yaml            # OPC UA 服务端配置
│   └── global_config.yaml           # 全局配置
│
├── docs_site/                       # 营销与推广材料
│   ├── flagship_article.md          # 立旗文章
│   ├── landing_page.md              # 产品页
│   └── sales_playbook.md            # 销售话术与转化流程
│
├── install.sh                       # 一键安装脚本
├── README.md                        # 你现在看的
└── CONTRIBUTING.md                  # 贡献指南
```

---

## 🚀 5 分钟快速体验

```bash
git clone https://github.com/yicechuhai/rk3588-industrial-toolkit.git
cd rk3588-industrial-toolkit
sudo bash install.sh
sudo bash /opt/rk3588-toolkit/env_check/check_env.sh
```

---

## 🔧 验证硬件

| 板卡 | 配置 | 状态 |
|------|------|------|
| NanoPC T6 | 8GB / 64GB | ✅ 主力开发板 |
| 鲁班猫 8 | 8GB / 128GB | ✅ 主力开发板 |
| Orange Pi 5 Max | 8GB+ | ✅ 已验证 |
| Radxa Rock 5B | 8GB+ | ✅ 已验证 |
| 飞凌 OK3588-C | 4GB+ | ✅ 理论兼容 |
| 触觉智能 IDO-SOM3588 | — | ✅ 理论兼容 |
| 东胜 DSOM-3588 | — | ✅ 理论兼容 |

---

## 📊 性能基准

| 指标 | 数值 | 条件 |
|------|------|------|
| **中断延迟** | < 20 μs (空闲) / < 50 μs (满载) | PREEMPT_RT + cyclictest |
| **YOLOv5s 推理** | 54+ FPS | 640×640 INT8, 3 NPU 核心 |
| **ResNet18 推理** | 244 FPS | 224×224 INT8 |
| **视频流水线 CPU** | < 15% | RGA 零拷贝模式 |

---

## 📖 文档导航

| 文档 | 语言 | 说明 |
|------|------|------|
| [开发指南](deploy/docs/zh/development_guide.md) | 中文 | 架构、集成、API、扩展 |
| [实时调优指南](deploy/docs/zh/realtime_tuning_guide.md) | 中文 | PREEMPT_RT 六步配置 |
| [FAQ](deploy/docs/zh/faq.md) | 中文 | 部署/NPU/实时/商业 |
| [Developer Guide](deploy/docs/en/development_guide.md) | EN | Architecture & API |
| [FAQ](deploy/docs/en/faq.md) | EN | Deployment & commercial |
| [销售话术](docs_site/sales_playbook.md) | 中文 | 客户转化全流程 |

---

## 💰 版本与定价

| 版本 | 价格 | 适用 |
|------|------|------|
| **社区版** | 免费 | 个人开发者、评估测试 |
| **标准订阅** | ¥9,800/年 | 中小方案商、需要技术支持 |
| **企业订阅** | ¥29,800/年 | 含远程支持 + 定制适配 |

---

## ⚖️ 技术承诺

- ✅ 仅使用主线 PREEMPT_RT，不依赖闭源 AMP
- ✅ 只分发源码脚本和补丁，不发布内核二进制
- ✅ 所有交付物未加密未混淆，你拥有完全自主权
- ✅ MVP 锁定 RK3588 + Ubuntu 22.04 + YOLOv5/v8

---

## 🤝 贡献

欢迎提交 Issues 和 PR！请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

---

## 📄 License

Apache 2.0 © 2026 [yicechuhai](https://github.com/yicechuhai)
