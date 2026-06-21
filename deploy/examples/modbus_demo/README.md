# Modbus TCP 映射示例

## 场景

流水线上有两条传送带，需要检测：
1. 包装箱是否到位
2. 叉车是否在危险区域

检测结果通过 Modbus TCP 推送到西门子 S7-1200 PLC。

## 接线

```
┌──────────────┐         Ethernet          ┌──────────────┐
│   RK3588     │───────────────────────────│  S7-1200 PLC  │
│  (Modbus     │  192.168.1.100:502        │  (Modbus     │
│   Server)    │                           │   Client)    │
└──────┬───────┘                           └──────┬───────┘
       │                                         │
   USB Camera                               Conveyor Belt
```

## PLC 端配置

在 TIA Portal 中添加 Modbus TCP 客户端：

| 寄存器 | 地址 | 含义 |
|--------|------|------|
| HR 40001 | MW100 | 心跳计数 |
| HR 40004 | MW106 | 检测到的目标数量 |
| HR 40005 | MW108 | 目标0 类别 ID |
| HR 40006 | MW110 | 目标0 置信度 (0-1000) |
| HR 40009 | MW116 | 目标0 中心点 X |
| HR 40010 | MW118 | 目标0 中心点 Y |

## 运行

```bash
# 1. 启动 RK3588 推理 + Modbus 服务
python3 deploy/protocol/modbus_server.py \
    --config configs/yaml_templates/modbus_mapping.yaml \
    --model /opt/rk3588-toolkit/models/yolov5s-640-640.rknn

# 2. 在 PLC 端读取寄存器
# 用 Modbus Poll 或 PLC 程序读取 40001-40104
```
