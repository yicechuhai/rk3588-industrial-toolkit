# YOLOv5 目标检测示例

## 前置条件

- RK3588 板卡
- Ubuntu 22.04
- USB 摄像头（或 MIPI CSI）
- NPU 驱动已安装

## 运行

```bash
# 环境检测
sudo bash deploy_scripts/env_check/check_env.sh

# 运行 Demo
sudo bash deploy_scripts/demo/run_yolov5_demo.sh
```

## 预期输出

- 终端显示每帧检测结果（类别 + 置信度 + 坐标）
- 检测画面通过 HDMI 输出到显示器
- 结果图片保存到 `detection_result.jpg`

## COCO 类别 (YOLOv5s)

支持 80 种常见物体检测，包括：人、车、自行车、摩托车、公共汽车、卡车、交通灯、停车标志、猫、狗、背包、行李箱、瓶子、杯子、叉子、刀、勺子、碗、香蕉、苹果、橙子、笔记本电脑、鼠标、键盘、手机、微波炉、冰箱、书、钟表、花瓶、剪刀、泰迪熊、吹风机、牙刷等。
