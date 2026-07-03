# NeoCertify 认证教程

> 🎯 使 RK3588-OpenLab 通过国产OS兼容性认证 (NeoCertify)

## 背景

NeoCertify 是国产化替代方案中的兼容性认证体系，确保软件在国产操作系统（麒麟、UOS、openEuler）和国产芯片（RK3588等 ARM64）上稳定运行。

通过认证意味着：
- ✅ 完整功能在国产 OS 上可用
- ✅ 性能不低于标称值的 90%
- ✅ 通过安全合规审查
- ✅ 可进入信创采购目录

## 1. 认证概述

### 认证流程

```
准备阶段          检测阶段             认证阶段
┌──────────┐    ┌──────────────┐    ┌─────────────┐
│ 编写申请  │───▶│ 自动兼容检测  │───▶│ 生成报告     │
│ 收集材料  │    │ (neocertify)  │    │ 提交审核     │
└──────────┘    └──────────────┘    └─────────────┘
                       │
                       ▼
                ┌──────────────┐
                │ 人工复核      │
                │ 颁发证书      │
                └──────────────┘
```

### 评分标准

| 类别 | 权重 | 通过线 |
|------|------|--------|
| 核心功能 | 40% | ≥36 |
| 性能基准 | 25% | ≥20 |
| 系统兼容性 | 20% | ≥16 |
| 安全性 | 10% | ≥8 |
| 文档完整性 | 5% | ≥4 |
| **总分** | **100%** | **≥80** |

## 2. 准备申请材料

### application.json

```json
{
    "application": {
        "name": "RK3588 Industrial Vision Toolkit",
        "version": "1.0.0",
        "vendor": "RK3588-OpenLab",
        "category": "industrial.vision",
        "description": "RK3588 工业AI视觉与实时控制中间件"
    },
    "target_platforms": [
        {"os": "kylinos-v10", "arch": "aarch64", "kernel": "5.10"},
        {"os": "uos-20", "arch": "aarch64", "kernel": "5.10"},
        {"os": "openeuler-22.03", "arch": "aarch64", "kernel": "5.10"}
    ],
    "dependencies": {
        "system": ["glibc>=2.28", "systemd"],
        "python": ["numpy", "opencv-python", "rknn-toolkit-lite2"],
        "drivers": ["rknpu", "rga", "mpp"]
    },
    "test_suites": {
        "unit": "tests/unit/",
        "integration": "tests/integration/test_pipeline.py",
        "benchmark": "tools/benchmark/benchmark.sh"
    }
}
```

## 3. 运行认证检测

### 自动检测

```bash
# 运行 NeoCertify 检测器
python3 middleware/os-compat-layer/neocertify_runner.py

# 带参数
python3 middleware/os-compat-layer/neocertify_runner.py \
    --config neocertify_application.json \
    --target kylinos-v10 \
    --strict \
    --output report.html
```

### 检测项目

| 检测项 | 方法 | 通过条件 |
|--------|------|----------|
| OS 识别 | `/etc/os-release` | 为目标 OS 之一 |
| 内核版本 | `uname -r` | >=5.10 |
| NPU 驱动 | `lsmod` + NDK API | rknpu 已加载 |
| RGA 驱动 | `lsmod` + RGA API | rga 已加载 |
| OpenCL | `clinfo` | 至少 1 个平台 |
| Python 环境 | `import` 测试 | 所有依赖可导入 |
| 推理功能 | `test_engine.py` | 通过率 100% |
| 协议功能 | `test_modbus.py`, `test_opcua.py` | 通过率 100% |
| 性能基准 | `benchmark.sh` | >=标称值 90% |
| 长期稳定性 | 24h 压力测试 | 无崩溃 |

## 4. 性能基准要求

| 指标 | 标称值 | 认证最低 (90%) |
|------|--------|---------------|
| NPU 推理 FPS | 46 | ≥41.4 |
| 端到端 FPS | 25.7 | ≥23.1 |
| 推理延迟 (ms) | 21.7 | ≤24.0 |
| 抖动 P99 (us) | <50 | <55 |
| CPU 使用率 (推理时) | <30% | <35% |
| 内存使用 | <2GB | <2.5GB |

```bash
# 运行基准测试
bash tools/benchmark/benchmark.sh --iterations 100 --save results.json

# 对比认证要求
python3 tools/benchmark/compare_benchmark.py \
    --actual results.json \
    --baseline baseline.json \
    --threshold 0.9
```

## 5. 测试命令汇总

```bash
# 1. 兼容性检测
python3 middleware/os-compat-layer/compat_checker.py

# 2. 单元测试
python3 -m pytest tests/unit/ -v --tb=short

# 3. 集成测试
python3 -m pytest tests/integration/ -v --tb=short

# 4. 性能基准
bash tools/benchmark/benchmark.sh

# 5. 完整认证流程
python3 middleware/os-compat-layer/neocertify_runner.py --full

# 6. 查看 HTML 报告
python3 -m http.server 9090  # 然后浏览器访问 report.html
```

## 6. 报告解读

### 通过案例

```
NeoCertify 认证报告
====================================
应用: RK3588 Industrial Vision Toolkit v1.0.0
平台: KylinOS V10 (aarch64)
日期: 2024-06-30

检测结果:
  [PASS] OS 兼容性        (20/20)
  [PASS] 核心功能          (40/40)
  [PASS] 性能基准          (22/25) ⚠️ 端到端 FPS 24.3 (目标 ≥23.1)
  [PASS] 安全性            (10/10)
  [PASS] 文档              (5/5)
  ─────────────────────────────────
  总分: 97/100 ✅ 通过

建议: 端到端 FPS 略低，考虑调整 CPU 频率策略。
```

### 未通过案例

```
  [FAIL] 系统兼容性        (14/20) ❌ OpenCL 未找到
  [PASS] 核心功能          (38/40)
  ...
  ─────────────────────────────────
  总分: 74/100 ❌ 未通过 (需要 ≥80)

操作: 安装 OpenCL ICD: sudo apt install ocl-icd-libopencl1
```

## 7. 常见未通过项及修复

| 未通过项 | 原因 | 修复 |
|----------|------|------|
| OpenCL 未找到 | 麒麟OS 路径差异 | `sudo apt install ocl-icd-libopencl1` |
| 性能不足 90% | CPU governor 为 ondemand | `cpufreq-set -g performance` |
| glibc 版本过低 | 老版本麒麟 | 联系麒麟升级或静态链接 |
| RGA 驱动未加载 | 内核模块缺失 | 从固件提取 `rga.ko` 并 insmod |
| systemd 服务异常 | 路径差异 | 检查 `/lib/systemd/system/` |
