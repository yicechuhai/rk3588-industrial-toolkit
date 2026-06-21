# 公司板卡测试 Cursor 完整指令

> **用法**：复制下面全部内容，粘贴给你公司电脑上的 Cursor。
> **前提**：
> - Cursor 已 clone `https://github.com/yicechuhai/rk3588-industrial-toolkit.git`
> - NanoPC T6 或 鲁班猫 8 已通过 SSH/USB 串口连接到这台电脑
> - 板卡已开机，IP 已知（或通过串口连接）

---

## 复制以下内容发给 Cursor：

```
你是我的板卡测试助手。我会告诉你板卡的连接方式，你负责在板卡上运行测试脚本，
然后把终端输出完整地贴到 GitHub Issues。

## 板卡信息

我今天要测试的板卡是：

[这里你填：NanoPC T6 / 鲁班猫 8]

连接方式：[SSH root@192.168.x.x / USB串口 COMx]

## 你的工作流程

### 步骤 1：连接板卡

先试着连接板卡，确认能通，然后告诉我连接成功。

SSH 方式连接示例：
```bash
ssh root@<IP地址>
# 或
ssh <用户名>@<IP地址>
```

如果是串口，告诉我你用的是什么终端工具（PuTTY / MobaXterm / 设备管理器里的 COM 口）。

### 步骤 2：克隆/更新仓库

在板卡上执行：
```bash
# 如果是第一次
git clone https://github.com/yicechuhai/rk3588-industrial-toolkit.git
cd rk3588-industrial-toolkit

# 如果已经克隆过，拉取最新代码
git pull origin master
```

### 步骤 3：运行环境检测

```bash
sudo bash deploy_scripts/env_check/check_env.sh
```

把终端完整输出截下来。关键信息：
- 板卡型号（开发板型号识别那行）
- NPU 设备是否 PASS
- RGA 是否 PASS
- 失败和警告的数量

### 步骤 4：运行 YOLO Demo

```bash
sudo bash deploy_scripts/demo/run_yolov5_demo.sh
```

当脚本问你摄像头来源时，选择 3（仅测试模型推理，不需要摄像头）。

记录 NPU 推理性能测试结果（FPS、平均耗时）。

### 步骤 5：提交测试报告到 GitHub Issues

把以上两步的完整终端输出整理成一条 Issue，发布到：
https://github.com/yicechuhai/rk3588-industrial-toolkit/issues

Issue 标题格式：
[测试报告] 板卡名 - 基线环境检测 - YYYY-MM-DD

Issue 内容模板：
```
## 测试报告

**板卡**：[板卡名]
**日期**：[日期]
**脚本版本**：master 分支最新

### 环境检测结果

[粘贴 check_env.sh 完整输出]

### Demo 运行结果

[粘贴 run_yolov5_demo.sh 的输出，特别是 NPU 推理性能数据]

### 板卡环境信息

- 内核：<uname -r>
- NPU 驱动版本：<cat /sys/class/misc/rknpu/version>
- 内存：<free -h 的 Mem 行>
```

### 步骤 6：检查是否有待测试的新脚本

去 https://github.com/yicechuhai/rk3588-industrial-toolkit/pulls 
查看是否有 Cursor 提交的 PR。如果有，切换到对应分支测试：

```bash
git fetch origin
git checkout <分支名>
# 运行 PR 中提到的脚本
bash patches/npu_driver/check_npu_driver.sh
# ... 等等
```

把测试结果以 PR Review 的形式贴到对应的 PR 页面。

## 重要规则

1. **终端输出必须原样粘贴**，不要截断、不要省略、不要总结。用 ``` 代码块包裹。
2. **如果脚本报错**，不要自己修代码。把完整的错误信息贴到 Issue 里，我来判断。
3. **如果连接不上板卡**，告诉我连接方式和你尝试过的 IP/串口号，不要放弃。
4. **每个脚本测完一条发一条 Issue**，不要攒着。
5. **测完别忘了断开 SSH 连接**。

## 现在就做

先连接板卡，告诉我连上了。然后按步骤 2→3→4→5 执行。
```

---

## 简化版（如果上面的太长，用这个）

```
我要在 [NanoPC T6 / 鲁班猫 8] 板卡上测试项目代码。

连接方式：[SSH root@192.168.x.x]

请依次执行：
1. SSH 连接板卡
2. cd ~ && git clone https://github.com/yicechuhai/rk3588-industrial-toolkit.git（如果已存在则 git pull）
3. cd rk3588-industrial-toolkit && sudo bash deploy_scripts/env_check/check_env.sh
4. sudo bash deploy_scripts/demo/run_yolov5_demo.sh（选3，不需要摄像头）
5. 把以上两步的完整终端输出粘贴到 https://github.com/yicechuhai/rk3588-industrial-toolkit/issues 新建一条 Issue，标题：[测试报告] 板卡名 - 基线 - 日期
6. 检查 https://github.com/yicechuhai/rk3588-industrial-toolkit/pulls 是否有待测试的 PR，如有则在板卡上测试并把结果贴到 PR 页面
```

---

## 第二天之后用这个（日常测试简化版）

```
连接板卡 [NanoPC T6 / 鲁班猫 8]，SSH 方式。

1. 拉取最新代码：cd ~/rk3588-industrial-toolkit && git pull origin master
2. 检查 https://github.com/yicechuhai/rk3588-industrial-toolkit/pulls 有没有新的 PR 标题包含 "feat" 或 "fix"
3. 如果有新 PR，切分支测试，把结果贴到 PR 页面
4. 如果没有新 PR，告诉我"今天没有需要测试的新代码"
```
