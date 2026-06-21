# 发给 Cursor 的完整启动命令

> **用法**：复制下面全部内容，直接发给 Cursor（或粘贴到 Cursor 的初始对话中）。
> **前提**：Cursor 已 clone `https://github.com/yicechuhai/rk3588-industrial-toolkit.git` 并切换到 `dev` 分支。

---

## 第一部分：项目背景（发给 Cursor）

```
你是这个项目的唯一主力开发。我是产品负责人，负责在 RK3588 开发板上测试你的代码。

## 项目概述

我们在做 RK3588 工业视觉与实时控制中间件。定位是：
"帮客户把 3 个月的内核与流水线调优压缩到半天评估 + 1 天集成"

技术路线：
- 只用主线 PREEMPT_RT，不碰闭源 AMP
- 只分发源码脚本和补丁，不发布内核二进制
- 锁定 RK3588 + Ubuntu 22.04 + YOLOv5/v8

## 测试平台

我有两块板卡，所有代码必须在这两块上测试通过：
- NanoPC T6 (8GB LPDDR4x + 64GB eMMC)
- 鲁班猫 8 (8GB LPDDR5 + 128GB eMMC)

两者关键差异见 HARDWARE_REFERENCE.md。

## 你的工作入口

请先完整阅读以下文件（按顺序）：
1. PROJECT_PLAN.md — 完整项目规划，你的任务在第三部分
2. HARDWARE_REFERENCE.md — 硬件差异
3. deploy_scripts/env_check/check_env.sh — 现有脚本风格参考
4. deploy_scripts/demo/run_yolov5_demo.sh — Demo 脚本参考
5. configs/yaml_templates/ — YAML 配置模板

## 你的第一个任务（立即开始）

创建分支 `feat/npu-driver`，实现两个脚本：

### 1. patches/npu_driver/check_npu_driver.sh
- 检测 NPU 驱动版本和 RKNN Runtime 版本
- 对比版本兼容性矩阵
- 输出 "✓ 匹配" 或 "✗ 不匹配" 及具体建议

### 2. patches/npu_driver/upgrade_npu_driver.sh
- 备份当前驱动状态
- 从 GitHub releases 下载匹配的 RKNN Runtime deb
- 安装并验证
- 失败时回滚

要求：
- 代码风格参考 check_env.sh
- 支持 sudo 和非 sudo 两种运行模式
- 所有输出中英文双语
- 错误处理完善，不允许静默失败

完成后提交 PR 到 master，我来测试。
```

---

## 第二部分：开发规范（发给 Cursor）

```
## 代码规范

### Shell 脚本
- 使用 `#!/bin/bash` + `set -e`
- 函数命名用下划线：`check_npu_driver()`
- 颜色定义统一用：
  RED='\033[0;31m'; GREEN='\033[0;32m'
  YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
- 检测结果统一调用 `check_result()` 函数（已在 check_env.sh 中定义，可复用）
- 每个脚本必须有 banner 打印版本号
- 每个脚本头部必须有中文注释块说明功能

### C++ 引擎
- C++17 标准
- CMake 构建系统
- 命名风格：类名 CamelCase，方法名 camelCase，成员变量 trailing_
- 依赖管理：rga、rknnrt 使用系统库，其他用 FetchContent 或 vcpkg
- 错误处理：返回错误码，不抛异常

### Python 脚本
- Python 3.9+
- 类型注解（Type Hints）
- 用 argparse 处理命令行参数
- 所有函数有 docstring

### 通用原则
- 不允许静默失败，每个错误都要输出到 stderr 并返回非零退出码
- 每个脚本都要有 `--help` 或 `-h` 选项
- 日志输出包含时间戳
- 不要在代码中硬编码 IP 地址、路径（用配置文件或环境变量）
```

---

## 第三部分：Git 分支与提交流程（发给 Cursor）

```
## 分支策略

永远从 master 切功能分支：
- feat/npu-driver     (当前任务)
- feat/rt-patch       (下一个)
- feat/offline-pack   (再下一个)
- feat/engine-sdk     (C++ SDK)
- feat/modbus-impl    (Modbus)
- feat/opcua-impl     (OPC UA)
- feat/docker         (容器化)

## Commit 规范

feat: 简短描述（中文）
fix: 修复内容
docs: 文档变更
refactor: 重构

示例：
feat: 实现 NPU 驱动版本检测脚本
fix: 修复鲁班猫8上 RGA 设备节点路径错误
docs: 更新 Modbus 映射配置示例

## 提交流程

1. 切分支：git checkout -b feat/npu-driver master
2. 开发 + 本地自测
3. 提交：git commit -m "feat: xxx"
4. 推送：git push origin feat/npu-driver
5. 在 GitHub 创建 PR → 我测试后合并
```

---

## 第四部分：完整任务队列（发给 Cursor）

```
## 你的完整开发队列（按顺序执行）

### P0：第一优先级（第1周完成）
- [ ] patches/npu_driver/check_npu_driver.sh    ← 当前任务
- [ ] patches/npu_driver/upgrade_npu_driver.sh
- [ ] patches/preempt_rt/apply_rt_patch.sh
- [ ] patches/preempt_rt/setup_realtime.sh
- [ ] deploy_scripts/offline_pack/build_offline.sh

### P1：第二优先级（第2-3周完成）
- [ ] deploy/protocol/modbus_server.py
- [ ] deploy/engine/CMakeLists.txt
- [ ] deploy/engine/include/rk3588_engine.h
- [ ] deploy/engine/include/rga_pipeline.h
- [ ] deploy/engine/include/inference_context.h
- [ ] deploy/engine/src/rk3588_engine.cpp
- [ ] deploy/engine/src/rga_pipeline.cpp
- [ ] deploy/engine/src/inference_context.cpp
- [ ] deploy/engine/python_bindings/pybind11_wrapper.cpp
- [ ] deploy/engine/python_bindings/__init__.py

### P2：第三优先级（第4-5周完成）
- [ ] deploy/protocol/opcua_server.py
- [ ] docker/Dockerfile.runtime
- [ ] docker/Dockerfile.modbus
- [ ] docker/Dockerfile.opcua
- [ ] docker/docker-compose.yml
- [ ] deploy/engine/examples/basic_inference.cpp
- [ ] deploy/engine/examples/camera_pipeline.cpp
- [ ] deploy/engine/examples/zero_copy_demo.py

所有文件的详细 API 设计见 PROJECT_PLAN.md 第三部分。
```

---

## 第五部分：我给你的测试反馈格式（发给 Cursor）

```
## 当收到我的测试反馈时

我会以这种格式提交反馈：

---
## 测试报告
板卡：NanoPC T6
日期：2026-06-22
脚本：check_npu_driver.sh
### 通过的
- [x] 驱动版本检测正确
### 失败的
- [ ] 检测不到 RKNN Runtime → 错误日志：xxx
### 环境信息
- 内核：5.10.160
- NPU 驱动：0.9.6
---

你需要：
1. 根据错误日志定位问题
2. 修复后在同一分支提交
3. 在 PR 中 @ 我重新测试

修复的优先级：两块板卡都失败 > 只有一块失败 > 功能建议
```

---

## 现在就做（发给 Cursor 的最后一句）

```
现在请先阅读 PROJECT_PLAN.md 和 HARDWARE_REFERENCE.md，
然后执行 P0 的第一个任务：实现 check_npu_driver.sh。
有问题随时问。
```
