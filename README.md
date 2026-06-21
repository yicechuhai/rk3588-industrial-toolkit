# RK3588 Industrial Vision & Real-time Control Toolkit

RK3588 工业视觉与实时控制中间件 — 让 RK3588 上的 AI 视觉部署从"3个月调优"压缩到"半天评估+1天集成"。

## 项目结构

```
rk3588-industrial-toolkit/
├── deploy/                          # 产品核心模块
│   ├── realtime/                    # 实时增强包
│   ├── engine/                      # 零拷贝推理引擎
│   ├── protocol/                    # 工业协议适配层
│   ├── docs/                        # 文档
│   │   ├── zh/                      # 中文文档
│   │   └── en/                      # English docs
│   └── examples/                    # 示例项目
│       ├── yolov5_demo/             # YOLO 目标检测 Demo
│       └── modbus_demo/             # Modbus 通信 Demo
├── deploy_scripts/                  # 一键部署工具
│   ├── env_check/                   # 环境检测脚本
│   ├── demo/                        # Demo 运行脚本
│   └── offline_pack/                # 离线包
├── tools/                           # 工具集
│   ├── diagnose/                    # 故障诊断工具
│   └── benchmark/                   # 性能基准测试
├── patches/                         # 补丁包
│   ├── preempt_rt/                  # PREEMPT_RT 补丁
│   └── npu_driver/                  # NPU 驱动补丁
└── configs/                         # 配置文件
    └── yaml_templates/              # YAML 配置模板
```

## 快速开始

```bash
# 在 RK3588 开发板上运行
git clone https://github.com/your-org/rk3588-industrial-toolkit
cd rk3588-industrial-toolkit

# 环境检测
sudo bash deploy_scripts/env_check/check_env.sh

# 运行 Demo
sudo bash deploy_scripts/demo/run_yolov5_demo.sh
```

## 版本

- **社区版**：开源免费，基础环境检测 + Demo 运行
- **标准版**：¥9,800/年，全量自动化部署 + 技术支持
- **企业版**：¥29,800/年，含限次远程支持 + 定制适配

## License

Apache 2.0
