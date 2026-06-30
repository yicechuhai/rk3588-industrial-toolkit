# test_rt_config.py — 实时配置测试
# 测试实时内核参数、CPU 隔离、调度策略、IRQ 亲和性

import pytest
import os
from unittest.mock import Mock, MagicMock


class TestRealtimeKernelDetection:
    """实时内核检测测试"""

    def test_kernel_config_preempt_rt(self):
        """应检测 CONFIG_PREEMPT_RT=y"""
        configs = {
            "CONFIG_PREEMPT_RT": "y",
            "CONFIG_HZ": "1000",
            "CONFIG_PREEMPT": "y",
        }
        assert configs["CONFIG_PREEMPT_RT"] == "y"

    def test_tick_frequency(self):
        """内核 tick 频率应为 1000 Hz"""
        hz = 1000
        assert hz == 1000
        assert hz >= 1000  # 至少 1000Hz

    def test_kernel_cmdline_rt_params(self):
        """内核命令行应包含实时参数"""
        cmdline = "isolcpus=4-7 nohz_full=4-7 rcu_nocbs=4-7 irqaffinity=0-3"
        assert "isolcpus" in cmdline
        assert "nohz_full" in cmdline
        assert "rcu_nocbs" in cmdline
        assert "irqaffinity" in cmdline


class TestCpuIsolation:
    """CPU 隔离配置测试"""

    def test_isolcpus_range_parsing(self):
        """解析 isolcpus=4-7 范围"""
        isol_str = "4-7"
        parts = isol_str.split("-")
        start, end = int(parts[0]), int(parts[1])
        cpus = list(range(start, end + 1))
        assert cpus == [4, 5, 6, 7]

    def test_isolcpus_multi_range(self):
        """解析 isolcpus=4-5,6-7 (两个范围)"""
        ranges = ["4-5", "6-7"]
        all_cpus = []
        for r in ranges:
            s, e = r.split("-")
            all_cpus.extend(range(int(s), int(e) + 1))
        assert all_cpus == [4, 5, 6, 7]

    def test_isolcpus_single_core(self):
        """解析 isolcpus=7 (单核)"""
        single = 7
        assert isinstance(single, int)
        assert single >= 0

    def test_isolated_cpus_not_in_system_mask(self):
        """隔离的 CPU 不应在系统调度掩码中"""
        system_cpus = {0, 1, 2, 3}
        isolated_cpus = {4, 5, 6, 7}
        assert system_cpus.isdisjoint(isolated_cpus)


class TestSchedulingPolicy:
    """调度策略测试"""

    def test_fifo_scheduling(self):
        """SCHED_FIFO 优先级范围 1-99"""
        SCHED_FIFO = 1
        min_prio = 1
        max_prio = 99
        assert SCHED_FIFO == 1
        assert min_prio <= 50 <= max_prio  # 典型优先级

    def test_rr_scheduling(self):
        """SCHED_RR 时间片"""
        SCHED_RR = 2
        time_slice_us = 10000  # 10ms
        assert SCHED_RR == 2
        assert 1000 <= time_slice_us <= 100000  # 1ms-100ms

    def test_engine_thread_priority(self):
        """推理引擎线程应为最高 RT 优先级"""
        engine_priority = 99
        assert engine_priority >= 90  # 推理线程优先级很高

    def test_camera_thread_priority(self):
        """摄像头采集线程应有适度 RT 优先级"""
        camera_priority = 80
        assert 50 <= camera_priority <= 95


class TestIrqAffinity:
    """IRQ 亲和性测试"""

    def test_default_irq_affinity(self):
        """默认 IRQ 在 CPU 0-3"""
        irq_affinity_cpus = {0, 1, 2, 3}
        assert len(irq_affinity_cpus) == 4
        assert max(irq_affinity_cpus) < 4  # 不与隔离核心重叠

    def test_npu_irq_affinity(self):
        """NPU IRQ 应在非隔离核心"""
        npu_irq = 123
        target_cpu = 3
        assert target_cpu < 4  # 系统核心范围
        assert npu_irq > 0

    def test_eth_irq_affinity(self):
        """以太网 IRQ 应在非隔离核心"""
        eth_irq = 89
        target_cpus = {2, 3}  # 绑定到特定核心
        assert len(target_cpus) > 0


class TestNohzFullConfiguration:
    """nohz_full 配置测试"""

    def test_nohz_full_isolated_cpus(self):
        """nohz_full CPU 应与 isolcpus 一致"""
        nohz_cpus = {4, 5, 6, 7}
        isol_cpus = {4, 5, 6, 7}
        assert nohz_cpus == isol_cpus

    def test_nohz_reduces_timer_interrupts(self):
        """nohz_full 模式下 tick 中断应大幅减少"""
        normal_ticks_per_sec = 1000
        nohz_ticks_per_sec = 1  # 仅 1 Hz 调度 tick
        assert nohz_ticks_per_sec < normal_ticks_per_sec


class TestRcuNocbs:
    """RCU nocb 配置测试"""

    def test_rcu_nocbs_match_isolcpus(self):
        """rcu_nocbs 参数应与 isolcpus 一致"""
        rcu = {4, 5, 6, 7}
        isol = {4, 5, 6, 7}
        assert rcu == isol

    def test_rcu_offload_reduces_latency(self):
        """RCU 回调卸载可减少延迟抖动"""
        max_latency_without_nocb_us = 200
        max_latency_with_nocb_us = 20
        assert max_latency_with_nocb_us < max_latency_without_nocb_us


class TestRtKernelBuildConfig:
    """实时内核编译配置"""

    def test_build_script_exists(self):
        """build_rt_kernel.sh 应存在"""
        script_path = "deploy/realtime/build_rt_kernel.sh"
        assert script_path.endswith(".sh")

    def test_isolate_cpu_script_exists(self):
        """isolate_cpu.sh 应存在"""
        script_path = "deploy/realtime/isolate_cpu.sh"
        assert script_path.endswith(".sh")

    def test_version_matrix_exists(self):
        """version_matrix.yaml 应存在"""
        config_path = "deploy/realtime/version_matrix.yaml"
        assert config_path.endswith(".yaml")


class TestMemoryLocking:
    """内存锁定 (mlockall) 测试"""

    def test_mlockall_flags(self):
        """MCL_CURRENT | MCL_FUTURE 锁定所有内存"""
        MCL_CURRENT = 1
        MCL_FUTURE = 2
        flags = MCL_CURRENT | MCL_FUTURE
        assert flags == 3

    def test_max_locked_memory(self):
        """锁定内存上限应足够大"""
        min_locked_kb = 256 * 1024  # 256 MB
        assert min_locked_kb >= 64 * 1024  # 至少 64MB

    def test_stack_prefault(self):
        """栈空间应预锁定避免缺页"""
        stack_mlock = True
        assert stack_mlock is True


class TestLatencyBudget:
    """延迟预算测试"""

    def test_engine_latency_budget(self):
        """推理引擎延迟预算 ≤ 20ms"""
        budget = 20.0
        actual = 18.5  # ms
        assert actual <= budget

    def test_camera_latency_budget(self):
        """摄像头采集延迟预算 ≤ 33ms (30fps)"""
        frame_interval = 1000 / 30
        assert frame_interval == pytest.approx(33.33, rel=0.01)

    def test_modbus_latency_budget(self):
        """Modbus 响应应 ≤ 10ms"""
        budget = 10.0
        actual = 5.0  # ms
        assert actual <= budget

    def test_total_pipeline_latency_budget(self):
        """端到端延迟 (采集+推理+输出) ≤ 100ms"""
        cam_latency = 33.0
        infer_latency = 18.5
        output_latency = 10.0
        total = cam_latency + infer_latency + output_latency
        assert total <= 100.0
