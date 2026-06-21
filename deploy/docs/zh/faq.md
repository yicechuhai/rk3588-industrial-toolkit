# 常见问题 FAQ

## 部署相关

### Q: 安装脚本要求 root 权限吗？
A: `install.sh` 会将文件写入 `/opt/rk3588-toolkit`，需要 root 权限。但生成的环境检测报告可在普通用户下查看。

### Q: 支持哪些 RK3588 板卡？
A: 已验证 NanoPC T6、鲁班猫 8、Radxa Rock 5B、Orange Pi 5 系列、飞凌 OK3588-C、触觉智能 IDO-SOM3588、东胜 DSOM-3588。理论支持所有运行 Ubuntu 22.04 + BSP 内核的 RK3588 板卡。

### Q: 可以在 Docker 中运行吗？
A: NPU 需要访问 `/dev/dri/renderD128` 设备节点，可以使用 `--device /dev/dri:/dev/dri` 参数映射。Modbus/OPC UA 协议适配层可完全容器化。

## NPU 相关

### Q: 模型转换失败怎么办？
A: 检查三点：
1. rknn-toolkit2 版本是否与 NPU 驱动版本匹配（见 `patches/npu_driver/README.md`）
2. 模型算子是否在支持列表中
3. 量化校准数据集是否正确
另可搜索 [rknn-toolkit2 Issues](https://github.com/airockchip/rknn-toolkit2/issues) 寻找相似问题。

### Q: 为什么 NPU 推理速度不稳定？
A: 可能原因：
- CPU 降频 → 固定频率
- NPU 温度过高导致降频 → 改善散热
- 多任务抢占 NPU → 使用 `npu_core_mask` 隔离

## 实时性相关

### Q: PREEMPT_RT 会影响 NPU 性能吗？
A: 基本不。NPU 是独立硬件单元，不依赖 CPU 调度。但在极端负载下，隔离核心的实时任务不会抢占 NPU 推理。

### Q: 能否在通用内核上直接运行？
A: 可以。推理引擎和协议适配层不依赖 PREEMPT_RT。但 Modbus 定时读取 / 中断触发功能在通用内核上延迟较大（可能达到毫秒级）。

## 商业相关

### Q: 社区版和标准版的区别？
A: 社区版开源免费，包含基础环境检测和 Demo 运行。标准版（¥9,800/年）包含全量自动化部署、NPU 驱动管理、性能诊断报告生成器、Modbus 映射等完整功能，并提供 48 小时内邮件支持。

### Q: 你们提供现场技术支持吗？
A: 不。我们提供远程 Issue/邮件支持。如需现场服务，可联系我们推荐合作系统集成商。

### Q: 如果你们倒闭了，我的系统还能跑吗？
A: 所有交付物都是源码脚本+YAML配置，不存在 vendor lock-in。即使我们停止服务，已部署的系统完全不受影响。未加密未混淆，你拥有完全的自主维护能力。
