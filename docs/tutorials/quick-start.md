# 5 分钟快速开始

> 🎯 目标：从零开始在 RK3588 板卡上运行 AI 视觉推理流水线

## 前提条件

- RK3588 / RK3588S 开发板（任意品牌）
- Ubuntu 22.04 / Debian 11+ / Armbian
- 网络连接（至少 1 GbE）
- USB 摄像头 或 RTSP 网络摄像头
- 终端访问（SSH 或直接连接）

## 步骤 1: 环境检查 (30秒)

```bash
# 验证内核版本
uname -r
# 期望: 5.10.x 或 6.1.x

# 验证 NPU 驱动已加载
lsmod | grep rknpu
ls /usr/lib/aarch64-linux-gnu/librknnrt.so

# 验证 RGA 驱动
lsmod | grep rga
```

如果 NPU 驱动未加载，运行：
```bash
sudo bash patches/npu_driver/check_npu.sh
```

## 步骤 2: 安装 RK3588-OpenLab (1分钟)

```bash
git clone https://gitee.com/RK3588kaifa/RK3588-OpenLab.git
cd RK3588-OpenLab
sudo bash middleware/os-compat-layer/one_click_install.sh
```

安装器会自动完成：
- 安装 Python 依赖 (rknn-toolkit-lite2, numpy, opencv-python)
- 配置 systemd 服务
- 验证 NPU/RGA 驱动
- 生成环境健康报告

## 步骤 3: 运行 AI 视觉流水线 (30秒)

```bash
# USB 摄像头
python3 inference/ai-vision/prod_pipeline.py --source 0

# RTSP 网络摄像头
python3 inference/ai-vision/prod_pipeline.py --source rtsp://192.168.1.100:554/stream

# 使用预置演示脚本
python3 tools/rtsp_detector.py --rtsp rtsp://admin:password@192.168.1.100:554/stream
```

你将看到类似输出：
```
[INFO] NPU initialized: RK3588, 3 cores
[INFO] Model loaded: yolov5s.rknn (640x640)
[INFO] Pipeline started
Frame  123 | FPS: 25.7 | Objs: 3 | person(0.95) car(0.87) truck(0.72)
Frame  124 | FPS: 25.7 | Objs: 2 | person(0.93) person(0.89)
```

## 步骤 4: 查看 Dashboard (30秒)

```bash
python3 inference/ai-vision/dashboard_server.py --port 8080
```

浏览器访问 `http://<板卡IP>:8080` 查看实时检测画面和性能监控。

## 步骤 5: (可选) 启动工业协议服务 (2分钟)

```bash
# Modbus TCP
sudo systemctl start rk3588-modbus
sudo systemctl status rk3588-modbus

# OPC UA
sudo systemctl start rk3588-opcua
sudo systemctl status rk3588-opcua
```

## 下一步

| 需求 | 文档 |
|------|------|
| 构建实时内核 | [rt-kernel-tutorial.md](rt-kernel-tutorial.md) |
| 配置 EtherCAT 主站 | [ethercat-tutorial.md](ethercat-tutorial.md) |
| 深度 AI 视觉教程 | [ai-vision-tutorial.md](ai-vision-tutorial.md) |
| 适配麒麟OS | [kylinos-tutorial.md](kylinos-tutorial.md) |
| 通过认证 | [neocertify-tutorial.md](neocertify-tutorial.md) |

## 常见问题

**Q: NPU 驱动未加载？**
```bash
sudo dmesg | grep rknpu
sudo modprobe rknpu
```

**Q: 推理 FPS 很低？**
- 确认输入分辨率为 640×640
- 检查 CPU 频率：`cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq`
- 确认散热良好，NPU 频率未降频

**Q: 摄像头打不开？**
- USB 摄像头: `ls /dev/video*`
- RTSP: `ffprobe rtsp://...` 验证流可访问
