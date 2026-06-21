# Frequently Asked Questions

## Deployment

**Q: Does install.sh require root?**
A: Yes, it writes to `/opt/rk3588-toolkit`. Generated reports are readable by non-root users.

**Q: What RK3588 boards are supported?**
A: Verified on NanoPC T6, LubanCat 8, Rock 5B, Orange Pi 5 series, Forlinx OK3588-C, IDO-SOM3588, Dusun DSOM-3588. Any RK3588 board running Ubuntu 22.04 + BSP kernel should work.

**Q: Can I run this in Docker?**
A: The NPU requires `/dev/dri/renderD128`. Use `--device /dev/dri:/dev/dri`. The protocol adapters (Modbus/OPC UA) are fully containerizable.

## NPU

**Q: Model conversion fails. What should I do?**
A: Check:
1. rknn-toolkit2 version matches NPU driver version (see `patches/npu_driver/README.md`)
2. All operators are in the supported list
3. Quantization calibration dataset is correct
Also search [rknn-toolkit2 Issues](https://github.com/airockchip/rknn-toolkit2/issues).

**Q: Why is NPU inference speed unstable?**
A: Likely causes: CPU throttling, NPU thermal throttling, or contention. Fix frequency and improve cooling.

## Realtime

**Q: Does PREEMPT_RT affect NPU performance?**
A: No. The NPU is an independent hardware unit. Real-time task scheduling does not preempt NPU inference.

**Q: Can I run without PREEMPT_RT?**
A: Yes. The inference engine and protocol adapters work on the stock kernel. However, Modbus timing accuracy will degrade to millisecond-level.

## Commercial

**Q: What is the difference between Community and Standard editions?**
A: Community (free, MIT-licensed) includes environment checks and basic demo. Standard (¥9,800/year) adds full auto-deployment, NPU driver management, diagnostic report generator, Modbus mapping, and 48-hour email support.

**Q: Do you offer on-site support?**
A: No. We provide remote support via email/GitHub Issues. For on-site needs, we can recommend partner system integrators.

**Q: What happens if your company shuts down?**
A: All deliverables are source scripts + YAML configs. Zero vendor lock-in. Your deployed systems continue running without any dependency on us.
