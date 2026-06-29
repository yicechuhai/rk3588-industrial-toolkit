# RK3588 Industrial Vision & Real-time Control Toolkit

**RK3588 工业视觉与实时控制中间件** — 让 AI 视觉部署从"3个月调优"压缩到"半天评估 + 1天集成"。

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-RK3588-orange)]()
[![Ubuntu](https://img.shields.io/badge/OS-Ubuntu%2022.04-brightgreen)]()

---

## 🎯 一句话

你不用再花 3 个月折腾内核、NPU 驱动和模型部署。脚本给你，跑一下就行。

---

## 📦 Project Structure / 项目结构

k3588-industrial-toolkit/
├── deploy_scripts/                  # ⭐ One-click Deploy
│   ├── env_check/check_env.sh       # Environment health report (HTML)
│   ├── demo/run_yolov5_demo.sh      # YOLOv5s real-time detection
│   ├── oneclick/web_config.sh       # TUI config wizard
│   └── offline_pack/                # Offline deployment pack
│
├── deploy/                          # Core Modules
│   ├── engine/                      # 🔥 Zero-Copy Inference Engine
│   │   ├── include/ (5 headers)     #   Engine, ModelLoader, Pre/PostProcessor, RGA
│   │   ├── src/ (6 .cpp files)      #   DMA-BUF + RGA + YOLOv5/v8/X
│   │   ├── python/                  #   pybind11 (NumPy zero-copy + Context Manager)
│   │   └── CMakeLists.txt          #   C++17 -> libengine.so
│   │
│   ├── protocol/                    # 🔥 Industrial Protocols
│   │   ├── modbus/                  #   Modbus TCP Server (libmodbus)
│   │   │   ├── src/                 #   Multi-client, register map, YAML-driven
│   │   │   └── CMakeLists.txt
│   │   └── opcua/                   #   OPC UA Server (open62541)
│   │       ├── src/                 #   20 detection slots, full info model
│   │       └── CMakeLists.txt
│   │
│   ├── realtime/                    # ⚡ Real-time Enhancement
│   │   ├── build_rt_kernel.sh      #   PREEMPT_RT auto-build (775 lines, 22 funcs)
│   │   ├── isolate_cpu.sh          #   CPU isolation + IRQ affinity tuning
│   │   └── version_matrix.yaml     #   7 BSP kernels mapped to RT patches
│   │
│   └── docker/                      # 🐳 Docker
│       ├── Dockerfile + .cross      #   ARM64 target / x86_64 cross-compile
│       ├── docker-compose.yml       #   inference + modbus + opcua
│       └── entrypoint.sh
│
├── patches/                         # Driver & Kernel Patches
│   ├── preempt_rt/                  #   RT patch scripts + version matrix
│   └── npu_driver/                  #   NPU driver check (448L) + upgrade (566L)
│
├── configs/                         # YAML Config Templates
│   ├── engine.yaml                  #   Inference engine config
│   └── yaml_templates/              #   modbus, opcua, global
│
├── tests/                           # 🧪 Test Suite — 45 tests, all green
│   ├── unit/
│   │   ├── test_engine.py           #   Engine API + NPU + NumPy
│   │   ├── test_modbus.py           #   Address parsing + concurrency
│   │   └── test_opcua.py            #   Node model + auth + endpoints
│   ├── integration/
│   │   └── test_pipeline.py         #   End-to-end latency + stability
│   └── conftest.py
│
├── tools/                           # Diagnostics & Benchmark
├── docs_site/                       # Marketing materials
├── install.sh                       # One-click installer (--full/--minimal/--ai-only)
├── CHANGELOG.md                     # v1.0.0 release notes
└── README.md
\
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


## 🗺️ 项目规划

**所有协作者必读**：[PROJECT_PLAN.md](PROJECT_PLAN.md) — 包含完整模块清单、Cursor 待实现列表、测试矩阵、协作流程和时间线。

---

## 📖 文档导航

### 协作指南（所有协作者必读）

| 文档 | 读者 | 说明 |
|------|------|------|
| [项目规划](PROJECT_PLAN.md) | 所有人 | 模块清单、里程碑、协作流程 |
| [每日计划](DAILY_PLAN.md) | 你（产品负责人） | 每天的具体测试任务 |
| [硬件档案](HARDWARE_REFERENCE.md) | Cursor + 你 | NanoPC T6 vs 鲁班猫8 差异 |
| [Cursor 启动命令](CURSOR_START_PROMPT.md) | 你→Cursor | 复制发给 Cursor 的完整指令 |
| [自动化配置](AUTOMATION_CONFIG.md) | 你 | 每日推送自动化设置 |

### 技术文档

| 文档 | 语言 | 说明 |
|------|------|------|
| [开发指南](deploy/docs/zh/development_guide.md) | 中文 | 架构、集成、API、扩展 |
| [实时调优指南](deploy/docs/zh/realtime_tuning_guide.md) | 中文 | PREEMPT_RT 六步配置 |
| [FAQ](deploy/docs/zh/faq.md) | 中文 | 部署/NPU/实时/商业 |

### 营销材料

| 文档 | 说明 |
|------|------|
| [立旗文章](docs_site/flagship_article.md) | CSDN/知乎/电子发烧友 |
| [产品页](docs_site/landing_page.md) | GitHub Pages 首页 |
| [销售话术](docs_site/sales_playbook.md) | 客户转化全流程 |

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




