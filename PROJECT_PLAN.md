# RK3588 Industrial Toolkit — 完整项目规划与协作指南

> **版本**：v2.0 | **更新**：2026-06-21 | **仓库**：[yicechuhai/rk3588-industrial-toolkit](https://github.com/yicechuhai/rk3588-industrial-toolkit)
>
> **适用读者**：
> - 🔴 **产品负责人（你）**：负责板卡测试、反馈结果、决策方向
> - 🟢 **Cursor（主力开发）**：负责所有代码实现、脚本编写、SDK 封装
> - 🟡 **Codex（文档/营销/审查）**：负责文档、推广、代码审查、市场材料

---

# 第一部分：项目全景

## 1.1 产品定位（一句话）

**不是卖黑盒镜像，而是卖"确定性调优能力 + 工业级工具链"。**

帮客户把"3个月的内核与流水线调优"压缩到"半天评估 + 1天集成"。

## 1.2 硬件锚点

| 板卡 | 规格 | 角色 |
|------|------|------|
| **NanoPC T6** | 8GB + 64GB eMMC | 🟢 主力测试平台 A（LPDDR4x） |
| **鲁班猫 8** | 8GB + 128GB eMMC | 🟢 主力测试平台 B（LPDDR5） |

两个平台覆盖不同内存类型和板卡生态，测试结果互补。

## 1.3 技术承诺（对外宣称的硬指标）

| 指标 | 承诺值 | 验证方式 |
|------|--------|---------|
| 中断延迟空闲 | < 20 μs | cyclictest -p99 -D300 |
| 中断延迟满载 | < 50 μs | stress-ng + iperf3 + NPU 推理并行 |
| YOLOv5s NPU 推理 | 50+ FPS | INT8, 640×640, 3 核 |
| 视频流水线 CPU 占用 | < 15% | RGA 零拷贝模式 |
| 一键部署时长 | < 5 分钟 | 从 git clone 到 YOLO 跑起来 |

## 1.4 法律防火墙（铁律）

- ❌ **绝不**分发编译好的内核二进制文件
- ✅ 只分发源码补丁 + 自动化编译脚本
- ✅ 不碰任何闭源 AMP（Xenomai、OpenAMP 等）
- ✅ 仅用主线 PREEMPT_RT（Linux 6.12 已合入）

---

# 第二部分：模块清单与当前完成度

```
████████████████████████████████████████████████████████████
█  模块                    Cursor    Codex     你(测试)
█                         (代码)    (文档)    (板卡验证)
████████████████████████████████████████████████████████████
█ 1. 一键部署工具          ████░░░░  ████████  ░░░░░░░░
█    check_env.sh          ████████  ████████  ░░░░░░░░
█    run_yolov5_demo.sh    ████████  ████████  ░░░░░░░░
█    install.sh            ████████  ████████  ░░░░░░░░
█    build_offline.sh      ░░░░░░░░  ░░░░░░░░  ░░░░░░░░
█
█ 2. 实时增强包            ░░░░░░░░  ████████  ░░░░░░░░
█    apply_rt_patch.sh     ░░░░░░░░  ████████  ░░░░░░░░
█    setup_realtime.sh     ░░░░░░░░  ████████  ░░░░░░░░
█    调优指南              ░░░░░░░░  ████████  ░░░░░░░░
█
█ 3. NPU 驱动管理          ░░░░░░░░  ████████  ░░░░░░░░
█    check_npu_driver.sh   ░░░░░░░░  ████████  ░░░░░░░░
█    upgrade_npu_driver.sh ░░░░░░░░  ████████  ░░░░░░░░
█
█ 4. 零拷贝推理引擎        ░░░░░░░░  ████████  ░░░░░░░░
█    C++ SDK               ░░░░░░░░  ░░░░░░░░  ░░░░░░░░
█    Python 绑定            ░░░░░░░░  ░░░░░░░░  ░░░░░░░░
█    RGA 流水线             ░░░░░░░░  ░░░░░░░░  ░░░░░░░░
█
█ 5. 工业协议适配层        ░░░░░░░░  ████████  ░░░░░░░░
█    Modbus TCP Server      ░░░░░░░░  ░░░░░░░░  ░░░░░░░░
█    OPC UA Server          ░░░░░░░░  ░░░░░░░░  ░░░░░░░░
█    YAML → 寄存器映射      ░░░░░░░░  ████████  ░░░░░░░░
█
█ 6. 诊断与基准工具        ████████  ████████  ░░░░░░░░
█    diagnose.sh            ████████  ████████  ░░░░░░░░
█    benchmark.sh           ████████  ████████  ░░░░░░░░
█
█ 7. 文档体系              ░░░░░░░░  ████████  ░░░░░░░░
█    开发指南 (中/英)       ░░░░░░░░  ████████  ░░░░░░░░
█    FAQ (中/英)            ░░░░░░░░  ████████  ░░░░░░░░
█    实时调优指南            ░░░░░░░░  ████████  ░░░░░░░░
█    API 文档               ░░░░░░░░  ████████  ░░░░░░░░
█
█ 8. 营销与销售            ░░░░░░░░  ████████  ░░░░░░░░
█    立旗文章               ░░░░░░░░  ████████  ░░░░░░░░
█    产品页                  ░░░░░░░░  ████████  ░░░░░░░░
█    销售话术                ░░░░░░░░  ████████  ░░░░░░░░
█
█ 9. GitHub 社区            ░░░░░░░░  ████████  ░░░░░░░░
█    CONTRIBUTING           ░░░░░░░░  ████████  ░░░░░░░░
█    Issue/PR 模板           ░░░░░░░░  ████████  ░░░░░░░░
████████████████████████████████████████████████████████████
```

---

# 第三部分：Cursor 待实现清单（按优先级）

## 🔴 P0：本周必须完成（阻塞板卡测试）

### 3.1 NPU 驱动管理脚本

**文件**：`patches/npu_driver/check_npu_driver.sh`
**功能**：
1. 检测当前 NPU 驱动版本（`cat /sys/class/misc/rknpu/version` 或 `dmesg | grep rknpu`）
2. 检测 RKNN Runtime 版本（`dpkg -l | grep rknn` 或 `ldconfig -p | grep librknnrt`）
3. 对比版本兼容性矩阵，输出"✓ 匹配"或"✗ 不匹配"
4. 如果不匹配，给出具体升级/降级建议

**文件**：`patches/npu_driver/upgrade_npu_driver.sh`
**功能**：
1. 备份当前驱动状态
2. 从 GitHub releases 或离线包下载匹配的 RKNN Runtime deb
3. 安装并验证（检查 `/dev/dri/renderD128` 是否重新出现）
4. 失败时回滚到备份

### 3.2 PREEMPT_RT 补丁自动化

**文件**：`patches/preempt_rt/apply_rt_patch.sh`
**功能**：
1. 检测当前 BSP 内核版本（`uname -r`）
2. 从瑞芯微 BSP 仓库下载对应内核源码
3. 从 kernel.org 下载匹配的 PREEMPT_RT 补丁
4. 自动打补丁、配置内核选项（`CONFIG_PREEMPT_RT=y` 等）
5. 编译 + 安装 + 更新启动项（extlinux.conf / armbianEnv.txt）
6. 提示重启

### 3.3 实时性调优配置

**文件**：`patches/preempt_rt/setup_realtime.sh`
**功能**：
1. 自动检测当前内核是否已启用 PREEMPT_RT
2. 添加启动参数：`isolcpus=4-7 nohz_full=4-7 rcu_nocbs=4-7 irqaffinity=0-3`
3. 安装 rt-tests、配置 CPU 隔离
4. 运行 cyclictest 并输出基线延迟报告

### 3.4 离线部署包构建

**文件**：`deploy_scripts/offline_pack/build_offline.sh`
**功能**：
1. 在联网的 RK3588 上运行，下载所有依赖的 deb 包
2. 打包 RKNN Runtime、Python 依赖（numpy/opencv）的离线安装包
3. 生成 `offline_install.sh` 供离线环境使用
4. 输出 `.tar.gz` 文件

---

## 🟡 P1：第2-3周（核心产品力）

### 3.5 零拷贝推理引擎 — C++ SDK

**目录**：`deploy/engine/`

```
deploy/engine/
├── CMakeLists.txt
├── include/
│   ├── rk3588_engine.h          # 顶层 API
│   ├── rga_pipeline.h           # RGA 硬件加速流水线
│   └── inference_context.h      # NPU 推理上下文
├── src/
│   ├── rk3588_engine.cpp
│   ├── rga_pipeline.cpp
│   └── inference_context.cpp
├── python_bindings/
│   ├── pybind11_wrapper.cpp     # pybind11 绑定
│   └── __init__.py
└── examples/
    ├── basic_inference.cpp
    ├── camera_pipeline.cpp
    └── zero_copy_demo.py
```

**API 设计**：

```cpp
class RK3588Engine {
public:
    // 初始化：加载模型、初始化 NPU、配置 RGA
    bool init(const EngineConfig& config);
    
    // 单帧推理（零拷贝：输入 DMA-BUF fd，输出 DMA-BUF fd）
    bool inferDmaBuf(int input_fd, std::vector<Detection>& results);
    
    // 摄像头流水线：抓帧→RGA缩放→NPU推理→RGA OSD→显示（全程零拷贝）
    bool runPipeline(const PipelineConfig& config, PipelineCallback cb);
    
    // 获取性能统计
    Stats getStats();
    
    // 释放资源
    void release();
};

struct Detection {
    int class_id;
    float confidence;
    Rect bbox;        // x1,y1,x2,y2
    Point center;     // cx,cy
    int area;
};
```

**关键要求**：
- 输入/输出使用 DMA-BUF，避免 CPU 侧的 memcpy
- RGA 做缩放+裁剪+颜色转换，不经过 CPU
- 支持 NV12 输入（摄像头原生格式），避免格式转换
- OSD 叠加也走 RGA

### 3.6 Modbus TCP 服务端

**文件**：`deploy/protocol/modbus_server.py`

**功能**：
1. 读取 `modbus_mapping.yaml` 配置
2. 启动 Modbus TCP 服务（端口 502）
3. 从推理引擎获取检测结果，映射到保持寄存器
4. 支持多客户端连接
5. 心跳机制（40001 自增）
6. 看门狗超时自动清零

### 3.7 OPC UA 服务端

**文件**：`deploy/protocol/opcua_server.py`

**功能**：
1. 读取 `opcua_server.yaml` 配置
2. 启动 OPC UA 服务（端口 4840）
3. 暴露设备信息、系统状态、检测结果节点
4. 支持订阅/事件推送

---

## 🟢 P2：第4-6周（打磨与扩展）

### 3.8 诊断报告生成器增强

**文件**：`tools/diagnose/diagnose.sh`（增强现有版本）

**增强功能**：
- HTML 报告增加 cyclictest 直方图（PNG 嵌入）
- 增加 DMA-BUF 内存泄漏检测
- 增加 NPU 温度趋势记录

### 3.9 Docker 容器化

**目录**：`docker/`

```
docker/
├── Dockerfile.runtime           # 推理引擎容器
├── Dockerfile.modbus            # Modbus 协议容器
├── Dockerfile.opcua             # OPC UA 容器
└── docker-compose.yml           # 一键编排
```

### 3.10 演示视频脚本

**文件**：`docs_site/demo_video_script.md`

**内容**：5 分钟演示视频分镜脚本（零拷贝推理 + Modbus 输出 + PLC 读取全部跑通）

---

# 第四部分：你的测试任务（板卡验证）

## 4.1 测试环境准备

### NanoPC T6 (8+64)

```bash
# 1. 确认镜像
lsb_release -a     # Ubuntu 22.04
uname -r           # 记录内核版本

# 2. 确认硬件
cat /proc/device-tree/model
free -h            # 确认 8GB
df -h              # 确认 64GB

# 3. 确认 NPU
ls -la /dev/dri/renderD128    # 应该存在
cat /sys/class/misc/rknpu/version  # 记录驱动版本
```

### 鲁班猫 8 (8+128)

```bash
# 同样流程，特别注意：
# 鲁班猫 8 是 LPDDR5，可能使用不同的 BSP 内核配置
# 记录所有差异点
```

## 4.2 测试矩阵

| 阶段 | 测试项 | T6 | 猫8 | 通过标准 |
|------|--------|----|-----|---------|
| **S1: 环境检测** | `check_env.sh` 全部 PASS | ☐ | ☐ | 0 FAIL, ≤5 WARN |
| **S2: Demo 运行** | `run_yolov5_demo.sh` 跑起来 | ☐ | ☐ | YOLOv5s 出检测框 |
| **S3: NPU 驱动** | `check_npu_driver.sh` | ☐ | ☐ | 版本匹配 |
| **S4: RT 补丁** | `apply_rt_patch.sh` 编译通过 | ☐ | ☐ | 重启后 uname -r 含 rt |
| **S5: 实时延迟** | cyclictest 300秒 | ☐ | ☐ | 空闲<20μs, 满载<50μs |
| **S6: 推理性能** | `benchmark.sh` NPU 部分 | ☐ | ☐ | YOLOv5s ≥50FPS |
| **S7: RGA 零拷贝** | C++ SDK camera_pipeline | ☐ | ☐ | CPU<15%, 无内存泄漏 |
| **S8: Modbus** | PLC/Modbus Poll 读取寄存器 | ☐ | ☐ | 检测结果正确映射 |
| **S9: 离线部署** | `build_offline.sh` 生成的包 | ☐ | ☐ | 离线环境下可安装 |

## 4.3 测试反馈模板

每次测试后，发给 Cursor 的 Issue/消息格式：

```
## 测试报告

**板卡**：[NanoPC T6 / 鲁班猫 8]
**日期**：[YYYY-MM-DD]
**脚本版本**：[commit hash]

### 通过的
- [ ] check_env.sh → 3 PASS
- [ ] run_yolov5_demo.sh → YOLOv5s 检测到 3 个目标

### 失败的
- [ ] check_env.sh → "NPU 驱动版本不匹配"
  - 当前驱动: 0.9.6
  - RKNN Runtime: 2.3.2
  - 错误日志: [粘贴]

### 性能数据
- cyclictest max: 38 μs (空闲)
- YOLOv5s FPS: 52
- CPU 占用: 18%

### 环境信息
- 内核: 5.10.160
- NPU 驱动: 0.9.6
- 摄像头: Logitech C920 USB
```

---

# 第五部分：协作流程

## 5.1 日常工作流

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│    Cursor     │────▶│     GitHub    │◀────│     Codex     │
│  (写代码)      │     │   (中央仓库)   │     │ (文档/审查)    │
└──────┬───────┘     └──────┬───────┘     └──────┬───────┘
       │                    │                    │
       │            ┌───────▼───────┐            │
       │            │      你        │            │
       │            │  (板卡测试)     │            │
       │            └───────┬───────┘            │
       │                    │                    │
       │         ┌─────────▼─────────┐          │
       └─────────┤   GitHub Issues   ├──────────┘
                 │  (测试反馈/Bug报告) │
                 └───────────────────┘
```

**每一步的具体操作**：

1. **Cursor 写代码** → 提交到 GitHub `dev` 分支
2. **Codex 审查代码** → Review PR，更新文档
3. **你拉取 `dev` 分支** → 在 NanoPC T6 / 鲁班猫 8 上测试
4. **你提交测试结果** → GitHub Issue，格式如上
5. **Cursor 修复** → 根据你的反馈改代码
6. **验证通过** → 合并到 `master`

## 5.2 分支策略

```
master          ← 稳定发布版（社区版始终可用）
  └── dev       ← 开发主分支（Cursor 日常提交到这里）
       ├── feat/npu-driver     ← NPU 驱动管理
       ├── feat/rt-patch       ← PREEMPT_RT 补丁
       ├── feat/engine-sdk     ← C++ 推理引擎
       ├── feat/modbus-impl    ← Modbus 服务端
       └── feat/opcua-impl     ← OPC UA 服务端
```

## 5.3 沟通渠道

| 场景 | 渠道 | 格式 |
|------|------|------|
| 测试反馈 | GitHub Issue | `[测试报告] 板卡名 - 脚本名` |
| Bug 报告 | GitHub Issue | `[BUG] 简短描述` |
| 功能需求 | GitHub Issue | `[FR] 简短描述` |
| 紧急问题 | 直接在 Codex 跟我说 | 我会帮你转成 Issue 或直接处理 |

---

# 第六部分：里程碑与时间线

## M1: 基础可用 (第 1-2 周) 🎯

- [ ] NPU 驱动管理脚本（check + upgrade）
- [ ] PREEMPT_RT 补丁脚本（apply + setup）
- [ ] 离线部署包构建脚本
- [ ] **你完成**：NanoPC T6 + 鲁棒猫 8 环境检测全部 PASS
- [ ] **你完成**：YOLOv5s Demo 在两个板卡上跑通

**验收标准**：一个新手拿 NanoPC T6，5 分钟内看到 YOLO 跑起来。

## M2: 核心产品力 (第 3-4 周) 🎯

- [ ] C++ 零拷贝推理引擎（基本版）
- [ ] Modbus TCP 服务端
- [ ] Python SDK 封装
- [ ] **你完成**：RGA 零拷贝流水线验证（CPU < 15%）
- [ ] **你完成**：Modbus Poll 能读到检测结果

**验收标准**：摄像头→NPU 推理→Modbus 寄存器，全程 50ms 内完成一帧。

## M3: 完整产品 (第 5-8 周) 🎯

- [ ] OPC UA 服务端
- [ ] Docker 容器化
- [ ] 性能诊断报告生成器增强
- [ ] **你完成**：PREEMPT_RT + NPU 推理 + Modbus 并行运行，延迟达标
- [ ] **你完成**：2 小时持续运行无内存泄漏、无崩溃

**验收标准**：可以拿出去给种子用户试用了。

## M4: 发布与推广 (第 9-12 周) 🎯

- [ ] 演示视频录制（Codex 写脚本，你录制）
- [ ] GitHub Pages 上线（Codex 配置）
- [ ] 立旗文章发布（CSDN/电子发烧友/知乎）
- [ ] **你完成**：联系 3-5 家板卡商谈合作
- [ ] **你完成**：首次直播技术分享

---

# 第七部分：Cursor 阅读指南

> Cursor，你好！以下是你的工作范围和当前状态。

## 你负责的部分

1. **所有 Shell 脚本**（`.sh` 文件）的编写和维护
2. **C++ SDK**（`deploy/engine/`）的开发
3. **Python 绑定和脚本**（`deploy/protocol/`、SDK 的 pybind11）
4. **Docker 容器**的编写
5. **CMakeLists.txt** 和构建系统

## Codex 负责的部分（已完成，后续增量更新）

1. 所有 Markdown 文档（`deploy/docs/`、`docs_site/`）
2. YAML 配置模板（`configs/`）
3. GitHub 社区建设（`.github/`、`CONTRIBUTING.md`）
4. 营销材料（立旗文章、产品页、销售话术）
5. 代码审查：你的 PR 合并前 Codex 会 Review

## 产品负责人负责的部分

1. 在 NanoPC T6 (8+64) 和鲁班猫 8 (8+128) 上测试你的代码
2. 以固定格式（见§4.3）提交测试反馈到 GitHub Issues
3. 决策产品方向和优先级
4. 对外推广和客户沟通

## 当前工作起点

- **你的第一个任务**：实现 `patches/npu_driver/check_npu_driver.sh` 和 `upgrade_npu_driver.sh`
- **参考文档**：`patches/npu_driver/README.md` 中的版本对应表
- **参考脚本风格**：`deploy_scripts/env_check/check_env.sh`
- **提交到**：`feat/npu-driver` 分支

---

# 第八部分：已知风险与注意事项

| 风险 | 应对 |
|------|------|
| NanoPC T6 vs 鲁棒猫 8 内核版本不一致 | Cursor 的脚本需要自动适配不同 BSP 内核 |
| NPU 驱动版本与 RKNN Toolkit 版本对应关系复杂 | 必须在 `check_npu_driver.sh` 中维护精确的版本矩阵 |
| RGA 在不同板卡上的 DMA-BUF 行为可能不同 | 需要你在两块板子上都验证 |
| PREEMPT_RT 补丁可能与某些 BSP 驱动冲突 | 你在测试时特别关注 WiFi/BT/ISP 是否正常工作 |
| 鲁棒猫 8 的 LPDDR5 可能与 PREEMPT_RT 有未知兼容问题 | 你在两块板子上都跑 cyclictest |

---

> **本文档位置**：仓库根目录 `PROJECT_PLAN.md`
> **最后更新**：2026-06-21
> **下次更新**：每两周，或在重大里程碑完成后
