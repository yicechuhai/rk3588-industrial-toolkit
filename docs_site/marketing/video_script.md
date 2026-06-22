# 演示视频拍摄脚本

> **时长**：5 分钟 | **用途**：B站 + 公众号 + 产品页
> **拍摄方式**：屏幕录制（OBS 免费），你只需要录像，我来剪辑和配音

---

## 分镜一：一句话破题（0:00-0:20）

**画面**：黑底白色大字逐行出现

```
在 RK3588 上部署 AI 视觉
从 3 个月 → 半天

怎么做到的？
```

**你录什么**：不用录。这是后期加的字幕。

---

## 分镜二：5 分钟跑通 YOLO（0:20-1:30）★ 需要你录

**画面**：终端操作全屏

**你录的操作**：
```
1. 打开终端
2. git clone https://github.com/yicechuhai/rk3588-industrial-toolkit.git
3. cd rk3588-industrial-toolkit && sudo bash install.sh
4. sudo bash deploy_scripts/env_check/check_env.sh
5. 手指指向屏幕上的 "✅ 所有检测通过"
6. sudo bash deploy_scripts/demo/run_yolov5_demo.sh
7. 选 3（仅推理测试）
8. 等 NPU 推理结果输出：54 FPS
```

**关键镜头**：FPS 数字出来后停留 3 秒，鼠标圈一下。

---

## 分镜三：零拷贝流水线（1:30-2:30）★ 需要你录

**画面**：摄像头实时画面 + 检测框 + 系统监控（htop）

**你录的操作**：
```
1. 接上 USB 摄像头
2. 运行带摄像头的 Demo（选 1）
3. 同时打开另一个终端跑 htop
4. 展示：检测框实时叠加在画面上，CPU 占用 < 15%
```

**关键镜头**：htop 里 RK3588 的 8 个核心，大部分空闲。

---

## 分镜四：结果发给 PLC（2:30-3:30）★ 需要你录

**画面**：左半边终端（Modbus Server 启动），右半边 Modbus Poll

**你录的操作**：
```
1. python3 deploy/protocol/modbus_server.py --config configs/yaml_templates/modbus_mapping.yaml
2. 在电脑上打开 Modbus Poll，连接 192.168.x.x:502
3. 展示：检测到人 → 40005 寄存器数字变化
```

**关键镜头**：摄像头里出现一个人 → Modbus Poll 里对应寄存器数字跳动。

---

## 分镜五：结尾引导（3:30-5:00）

**画面**：回到黑底白字

```
全开源 · Apache 2.0
GitHub: yicechuhai/rk3588-industrial-toolkit

社区版：免费
标准版：¥9,800/年

扫码加入技术交流群
[你的微信群二维码]

你的 RK3588 项目
值得更快一点
```

**你录什么**：不用录。后期加。

---

## 你现在要录的

只需录 **分镜二、三、四**，总共约 3 分钟的原始屏幕录像。

用 OBS（免费，obsproject.com）录屏，设置：
- 分辨率：1920×1080
- 帧率：30fps
- 格式：MP4
- 音频：不需要（我后期配音）

录好把 MP4 发给我，我处理剩下的：剪辑 + 字幕 + 背景音乐 + 配音 + 上传 B站。

---

## 补充：不需要摄像头录屏——用终端录制

你让公司 Cursor 在板卡上直接跑 `script` 命令即可录下终端操作。

### 方法一：终端回放（最简单，不需要任何软件）

```bash
# 在板卡上，通过 SSH 执行
script -t 2> timing.log -a output.session

# 然后执行你的演示命令：
sudo bash deploy_scripts/env_check/check_env.sh
sudo bash deploy_scripts/demo/run_yolov5_demo.sh

# 录完退出
exit
```

这会生成两个文件：
- `output.session` — 终端输出
- `timing.log` — 时间戳

回放：
```bash
scriptreplay timing.log output.session
```

### 方法二：用 asciinema（推荐，可以嵌入网页）

```bash
# 安装（如果板卡有网）
sudo apt install asciinema

# 录制
asciinema rec demo.cast

# 执行演示命令...
# Ctrl+D 结束录制

# 上传到 asciinema.org（可选，获得分享链接）
asciinema upload demo.cast
```

### 方法三：你电脑上用 OBS 录 SSH 窗口

公司 Cursor 什么都不用做。你在你的电脑上：
1. 打开 OBS
2. 添加"窗口捕获" → 选 SSH 终端窗口
3. 开始录制
4. 让公司 Cursor 在板卡上跑命令
5. 你在 OBS 上看到输出 → 录的就是你电脑上 SSH 窗口的画面

**这个方法最省事**—你不需要任何板卡上的操作，只需要用 OBS 录你电脑上 SSH 连接的窗口。
