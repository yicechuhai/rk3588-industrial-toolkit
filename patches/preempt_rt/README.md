# PREEMPT_RT 实时补丁

## 免责声明

本目录仅包含**自动化编译脚本和补丁说明**，不包含任何编译好的内核二进制文件。
用户需在自己的 RK3588 设备上运行脚本完成编译和安装。

## 使用方法

```bash
# 1. 安装编译依赖
sudo apt install -y build-essential libncurses-dev bison flex libssl-dev libelf-dev

# 2. 运行补丁脚本
bash apply_rt_patch.sh

# 3. 按提示完成内核编译、安装和重启
```

## 预期效果

- 中断延迟 < 50μs（实测可达 19-21μs）
- 支持 cyclictest 压测验证

## 技术说明

本补丁基于 Linux 社区主线 PREEMPT_RT 补丁（Linux 6.12 已正式合入），
通过以下策略实现硬实时性能：

1. CPU 隔离（isolcpus）：将 4-7 号核心专用于实时任务
2. 中断亲和力绑定：将非关键中断绑定到 0-3 号核心
3. 禁用 CPU 空闲/调频：消除调度延迟
4. nohz_full + rcu_nocbs：减少内核抖动

## 许可证

本脚本采用 Apache 2.0。PREEMPT_RT 补丁本身遵循 GPLv2。
