# OS 兼容层 API (os-compat-api)

> **支持系统**: KylinOS V10 / UOS (Deepin) / openEuler / Ubuntu  
> **认证**: NeoCertify 标准化检测流程

## 兼容性检测

### CompatChecker

```python
from rk3588_os_compat import CompatChecker

checker = CompatChecker(
    target_os="kylinos",     # kylinos | uos | openeuler
    strict_mode=False        # True: 按 NeoCertify 标准严格检查
)

results = checker.check_all()

# results 结构:
{
    "kernel": {
        "version": "5.10.0-rt17",
        "preempt_rt": True,
        "compatible": True
    },
    "drivers": {
        "npu": {"loaded": True, "version": "1.6.0"},
        "rga": {"loaded": True, "version": "2.2.0"},
        "mpp": {"loaded": True, "version": "1.0.0"}
    },
    "system_libs": {
        "glibc": "2.35",
        "openssl": "3.0.2"
    },
    "score": 95  # 兼容性评分
}
```

### API

| 方法 | 说明 |
|------|------|
| `CompatChecker(target_os, strict_mode)` | 创建检测器 |
| `check_all()` → dict | 全量检测 |
| `check_kernel()` → dict | 内核检测 |
| `check_drivers()` → dict | 驱动检测 |
| `check_libraries()` → dict | 系统库检测 |
| `generate_report()` → str | 生成 HTML 报告 |

## 麒麟OS 适配

```python
from rk3588_os_compat import KylinosAdapter

adapter = KylinosAdapter()

# 一键适配
adapter.adapt()  # 配置源、安装依赖、打补丁

# 分步执行
adapter.configure_apt_source()
adapter.install_dependencies()    # rknn-toolkit-lite2 等
adapter.apply_kernel_patches()    # PREEMPT_RT 补丁
adapter.configure_services()      # systemd 服务
adapter.verify()                  # 跑 self-test
```

### Shell 工具

```bash
# 一键安装
sudo bash middleware/os-compat-layer/one_click_install.sh

# 兼容性检测
python3 middleware/os-compat-layer/compat_checker.py

# 麒麟OS 专项
python3 middleware/os-compat-layer/kylinos_compat.py

# AMP 调度器配置
sudo bash middleware/os-compat-layer/amp_scheduler.sh
```

## NeoCertify 认证

```python
from rk3588_os_compat import NeoCertifyRunner

runner = NeoCertifyRunner(
    application_json="neocertify_application.json"
)

# 运行认证流程
result = runner.run()
# result.passed: bool
# result.score: int
# result.report_path: str
```

### application.json 结构

```json
{
    "application": {
        "name": "RK3588 Industrial Vision",
        "version": "1.0.0",
        "vendor": "RK3588-OpenLab",
        "category": "industrial"
    },
    "requirements": {
        "os": ["kylinos-v10", "uos-20"],
        "arch": "aarch64",
        "kernel": ">=5.10",
        "dependencies": [
            "librknnrt.so",
            "libOpenCL.so",
            "python3-rknnlite"
        ]
    },
    "tests": {
        "unit": "tests/unit/",
        "integration": "tests/integration/",
        "benchmark": "tools/benchmark/"
    }
}
```

## ASYNC/AMP 调度器

```python
from rk3588_os_compat import AMPScheduler

scheduler = AMPScheduler(
    big_cores=[4,5,6,7],   # A76 大核: 实时任务
    little_cores=[0,1,2,3] # A55 小核: 非实时
)

scheduler.assign("ethercat", cores=[6,7], policy="fifo", priority=99)
scheduler.assign("inference", cores=[4,5], policy="rr", priority=50)
scheduler.assign("dashboard", cores=[0,1,2,3])
scheduler.apply()
```

## 常用命令

```bash
# OpenCL 库路径确认
ls /usr/lib/aarch64-linux-gnu/libOpenCL.so*

# NPU 驱动版本
cat /sys/kernel/debug/rknpu/version

# RGA 驱动状态
cat /sys/kernel/debug/rkrga/load

# CPU 频率
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq

# 国产OS 识别
cat /etc/os-release | grep -E "^ID=|^VERSION="
```
