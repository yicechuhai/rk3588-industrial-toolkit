# 工业协议 API (protocol-api)

> **协议栈**: Modbus TCP / OPC UA / EtherCAT (IgH) / CAN FD  
> **语言**: Python + C (pybind11)

## Modbus TCP Server

```python
from rk3588_protocol import ModbusServer

server = ModbusServer(
    config="configs/modbus.yaml",  # 寄存器映射
    host="0.0.0.0",
    port=502
)

# 启动 (阻塞)
server.start()

# 或作为 systemd 服务
# sudo systemctl start rk3588-modbus
```

### 寄存器映射 (YAML)

```yaml
# configs/modbus.yaml
registers:
  holding:  # 4xxxx
    - address: 0
      name: "detection_count"
      type: uint16
      description: "当前帧检测目标数"
    - address: 1
      name: "inference_fps"
      type: float32  # 占 2 个寄存器
      description: "推理帧率"
    
  input:  # 3xxxx
    - address: 0
      name: "npu_temp"
      type: float32
      description: "NPU 温度 (°C)"
    
  coils:  # 0xxxx
    - address: 0
      name: "inference_enable"
      type: bool
      description: "推理开关"
```

### API

| 方法 | 说明 |
|------|------|
| `ModbusServer(config, host, port)` | 初始化服务器 |
| `start()` | 启动服务 (阻塞) |
| `stop()` | 停止服务 |
| `update_register(addr, value)` | 更新寄存器值 |
| `get_status()` → dict | 获取连接状态 |

## OPC UA Server

```python
from rk3588_protocol import OPCUAServer

server = OPCUAServer(
    config="configs/opcua.yaml",
    endpoint="opc.tcp://0.0.0.0:4840",
    security_policy="Basic256Sha256"  # 可选
)

server.start()
```

### 信息模型

```
Objects/
├── RK3588/
│   ├── Detection/
│   │   ├── Slot_0..19/          # 20 个检测槽位
│   │   │   ├── ClassID (Int32)
│   │   │   ├── Confidence (Double)
│   │   │   ├── BBox/ (X1,Y1,X2,Y2)
│   │   │   └── Label (String)
│   │   └── Count (Int32)
│   ├── System/
│   │   ├── NPUTemp (Double)
│   │   ├── CPULoad (Double)
│   │   └── MemUsage (Double)
│   └── Control/
│       ├── InferenceEnable (Boolean)
│       └── ModelSwitch (String)
```

### API

| 方法 | 说明 |
|------|------|
| `OPCUAServer(config, endpoint, security_policy)` | 初始化 |
| `start()` | 启动服务器 |
| `stop()` | 停止 |
| `update_detections(detections: list[Detection])` | 更新检测数据到节点 |

## EtherCAT (IgH Master)

```python
from rk3588_protocol import EtherCATMaster

master = EtherCATMaster(
    interface="eth0",          # 网卡接口
    cycle_time_us=1000,        # 周期 (微秒)
    slaves_config="configs/ethercat.yaml"
)

# 注册从站 PDO 回调
@master.on_pdo(alias=0, direction="input")
def on_input(pdo_data: bytes):
    ...

master.start()
```

### YAML 从站配置

```yaml
# configs/ethercat.yaml
slaves:
  - alias: 0
    vendor_id: 0x00000002
    product_id: 0x00000001
    name: "Beckhoff EL1008"
    pdos:
      - index: 0x1A00
        name: "Inputs"
        entries:
          - name: "Channel1"
            type: bit
```

### 关键 API

| 方法 | 说明 |
|------|------|
| `EtherCATMaster(interface, cycle_time_us, slaves_config)` | 初始化主站 |
| `scan()` → list[SlaveInfo] | 扫描从站 |
| `start()` | 启动周期性通信 |
| `stop()` | 停止 |
| `on_pdo(alias, direction)` | PDO 回调装饰器 |
| `write_sdo(slave, index, subindex, data)` | SDO 写 |
| `read_sdo(slave, index, subindex)` → bytes | SDO 读 |

## 全局配置

```yaml
# configs/global.yaml
protocols:
  modbus:
    enabled: true
    port: 502
  opcua:
    enabled: true
    port: 4840
  ethercat:
    enabled: false  # 需 PREEMPT_RT 内核
    interface: eth0
    cycle_time_us: 1000

rt:
  cpu_mask: "0xf0"    # CPU 4-7 用于实时协议
  irq_affinity: true
```
