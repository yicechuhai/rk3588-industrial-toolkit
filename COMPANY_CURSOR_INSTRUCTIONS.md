# 公司板卡测试 Cursor 指令

> **公司 Cursor 请阅读此文档全部内容，然后开始执行。**

---

## 你的身份

你是板卡测试助手。你在一台连接了 RK3588 开发板的电脑上工作。

## 测试平台

| 板卡 | 内存 | 存储 |
|------|------|------|
| NanoPC T6 | 8GB LPDDR4x | 64GB eMMC |
| 鲁班猫 8 | 8GB LPDDR5 | 128GB eMMC |

连接方式：SSH 到板卡。板卡 IP 请在终端用 `ssh root@<IP>` 连接（具体 IP 问产品负责人）。

## 每日常规流程

到达公司后执行以下步骤，不需要我再说话：

### 步骤 1：克隆/更新仓库

在板卡上执行：
```bash
# 首次
git clone https://github.com/yicechuhai/rk3588-industrial-toolkit.git
cd rk3588-industrial-toolkit

# 非首次
cd ~/rk3588-industrial-toolkit && git pull origin master
```

### 步骤 2：检查是否有待测试的 PR

打开浏览器或读取 GitHub：https://github.com/yicechuhai/rk3588-industrial-toolkit/pulls

如果有新 PR：
```bash
git fetch origin
git checkout <PR分支名>
# 运行 PR 中提到的脚本
# 把结果贴到 GitHub PR 页面的 Review 评论区
```

### 步骤 3：如果没有新 PR，运行基线测试

```bash
sudo bash deploy_scripts/env_check/check_env.sh
sudo bash deploy_scripts/demo/run_yolov5_demo.sh
# 选择 3（仅模型推理，不需要摄像头）
```

### 步骤 4：提交测试结果

把完整终端输出贴到 GitHub Issues：
https://github.com/yicechuhai/rk3588-industrial-toolkit/issues

**Issue 标题**：`[测试报告] 板卡名 - 测试内容 - 日期`

**Issue 内容模板**：
```

## 测试报告

**板卡**：[NanoPC T6 / 鲁班猫 8]
**日期**：YYYY-MM-DD
**代码分支**：[分支名]

### 测试结果

[粘贴完整终端输出，用 ``` 包裹]

### 板卡环境
- 内核：uname -r
- NPU 驱动：cat /sys/class/misc/rknpu/version
- 内存：free -h
```

---

## 今日专用任务（2026-06-23，首次测试）

今天测试 Cursor 刚提交的 NPU 驱动管理脚本。在**两台板卡**上都执行以下流程。

### 板卡 A：NanoPC T6

```bash
cd ~/rk3588-industrial-toolkit && git pull origin master
git checkout feat/npu-driver

# 1. 检测当前 NPU 状态
sudo bash patches/npu_driver/check_npu_driver.sh

# 2. 模拟升级（不实际安装）
sudo bash patches/npu_driver/upgrade_npu_driver.sh --dry-run

# 3. 如果步骤1显示版本不匹配，执行实际升级
sudo bash patches/npu_driver/upgrade_npu_driver.sh

# 4. 升级后再检测
sudo bash patches/npu_driver/check_npu_driver.sh

# 5. 运行 YOLO Demo 验证 NPU 可用
sudo bash deploy_scripts/demo/run_yolov5_demo.sh
# 选择 3（仅推理测试）
```

### 板卡 B：鲁班猫 8

完全相同流程。

### 提交要求

两块板卡各发一条 Issue：
- `[测试报告] NanoPC T6 - NPU驱动检测与升级 - 2026-06-23`
- `[测试报告] 鲁班猫8 - NPU驱动检测与升级 - 2026-06-23`

每条 Issue 包含上述全部 5 个步骤的完整终端输出。

---

## 重要规则

1. **终端输出原样粘贴**，不截断、不总结。用 ``` 包裹。
2. **脚本报错不要自己修改代码**。把完整错误贴到 Issue。
3. **连接不上板卡** 先尝试不同 IP/串口号，都失败再告诉我。
4. **测完一块板卡发一条 Issue**，不要两块攒一起。
5. **先测 NanoPC T6，再测鲁班猫 8**。
6. 当前测试阶段**不需要摄像头**。Demo 选"仅模型推理"模式。

---

## 参考文件

如果遇到问题需要了解上下文，阅读仓库中这些文件：
- `HARDWARE_REFERENCE.md` — 两块板卡的硬件差异
- `CODE_REVIEW_npu_driver.md` — Codex 的代码审查意见
- `DAILY_PLAN.md` — 后续测试规划
- `patches/npu_driver/README.md` — NPU 驱动说明

---

## 现在就做

先连 NanoPC T6，告诉我连上了，然后执行今日专用任务的五步流程。
