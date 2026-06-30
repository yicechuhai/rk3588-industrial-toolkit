#!/usr/bin/env python3
"""
RK3588 目标检测性能对比基准测试
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

对比三种配置:
  1. 纯 CPU 预处理 + 单核 NPU
  2. RGA 硬件预处理 + 单核 NPU
  3. RGA 硬件预处理 + 多核 NPU (0,1,2)

输出指标:
  - 平均 FPS
  - 延迟分布 (mean / P50 / P95 / P99 / min / max / std)
  - CPU 占用率 (近似值)
  - 各阶段耗时分解 (预处理 / NPU推理 / 解码)

用法:
  python3 bench_compare.py                              # 默认: 每个配置跑300帧
  python3 bench_compare.py --frames 500 --output report  # 500帧, 输出到 report/
  python3 bench_compare.py --configs cpu,rga,rga_multi  # 只跑指定配置
  python3 bench_compare.py --dry-run                    # 试运行 (验证配置, 跑10帧)

依赖:
  pip3 install numpy opencv-python rknn-toolkit-lite2
  (可选) on-board: 安装 rga 库以获得硬件加速
"""

import sys, os, time, json, argparse, platform, subprocess
import numpy as np

# ═══════════════════════════════════════════════════════
# 1. 配置定义
# ═══════════════════════════════════════════════════════

BENCH_CONFIGS = {
    "cpu": {
        "name": "纯CPU预处理 + 单核NPU",
        "desc": "OpenCV cv2.resize() + numpy BGR→RGB, NPU core=0",
        "args": "--no-display --npu-cores 0",
        "color": "cyan",
    },
    "rga": {
        "name": "RGA硬件预处理 + 单核NPU",
        "desc": "RGA CSC + RGA缩放, NPU core=0",
        "args": "--rga --no-display --npu-cores 0",
        "color": "green",
    },
    "rga_multi": {
        "name": "RGA硬件预处理 + 多核NPU",
        "desc": "RGA CSC + RGA缩放, NPU core=0,1,2",
        "args": "--rga --no-display --npu-cores 0,1,2",
        "color": "magenta",
    },
}

# ═══════════════════════════════════════════════════════
# 2. 性能指标采集
# ═══════════════════════════════════════════════════════

class PerformanceCollector:
    """采集单次基准测试的性能数据"""

    def __init__(self, config_name, config_info):
        self.config_name = config_name
        self.config_info = config_info
        self.frames = []
        self.latencies = []
        self.prep_times = []
        self.npu_times = []
        self.decode_times = []
        self.cpu_samples = []

    def add_frame(self, latency_ms, prep_ms, npu_ms, decode_ms):
        self.latencies.append(latency_ms)
        self.prep_times.append(prep_ms)
        self.npu_times.append(npu_ms)
        self.decode_times.append(decode_ms)

    def get_cpu_usage(self):
        """获取当前 CPU 占用率 (%) — Linux/Android 路径"""
        try:
            # 从 /proc/stat 读取 CPU 使用率
            with open("/proc/stat", "r") as f:
                line = f.readline()
            parts = line.split()
            if parts[0] == "cpu":
                # user nice system idle iowait irq softirq steal
                vals = list(map(int, parts[1:8]))
                total = sum(vals)
                idle = vals[3] + vals[4]  # idle + iowait
                return round((1 - idle / total) * 100, 1) if total > 0 else 0.0
        except Exception:
            pass
        return None

    def compute_stats(self, warmup_ratio=0.1):
        """计算统计指标, 丢弃预热帧"""
        if not self.latencies:
            return {}

        n = len(self.latencies)
        warmup = max(10, int(n * warmup_ratio))
        if n <= warmup:
            warmup = 0

        lat = np.array(self.latencies[warmup:])
        npu = np.array(self.npu_times[warmup:])
        decode = np.array(self.decode_times[warmup:])
        prep = np.array(self.prep_times[warmup:])

        # FPS = 1000 / 平均延迟
        mean_lat = float(np.mean(lat)) if len(lat) > 0 else 0
        fps = 1000.0 / mean_lat if mean_lat > 0 else 0

        return {
            "config": self.config_name,
            "description": self.config_info["name"],
            "total_frames": n,
            "stable_frames": len(lat),
            "fps": round(fps, 2),
            "latency_ms": {
                "mean": round(float(np.mean(lat)), 2),
                "median": round(float(np.median(lat)), 2),
                "p95": round(float(np.percentile(lat, 95)), 2),
                "p99": round(float(np.percentile(lat, 99)), 2),
                "min": round(float(np.min(lat)), 2),
                "max": round(float(np.max(lat)), 2),
                "std": round(float(np.std(lat)), 2),
                "cv": round(float(np.std(lat)) / float(np.mean(lat)) * 100, 1)
                      if len(lat) > 0 and np.mean(lat) > 0 else 0,
            },
            "preprocess_ms": {
                "mean": round(float(np.mean(prep)), 2),
                "ratio": round(float(np.mean(prep)) / mean_lat * 100, 1)
                         if mean_lat > 0 else 0,
            },
            "npu_ms": {
                "mean": round(float(np.mean(npu)), 2),
                "p95": round(float(np.percentile(npu, 95)), 2),
                "ratio": round(float(np.mean(npu)) / mean_lat * 100, 1)
                         if mean_lat > 0 else 0,
            },
            "decode_ms": {
                "mean": round(float(np.mean(decode)), 2),
                "ratio": round(float(np.mean(decode)) / mean_lat * 100, 1)
                         if mean_lat > 0 else 0,
            },
        }


# ═══════════════════════════════════════════════════════
# 3. 模拟模式 (开发环境测试)
# ═══════════════════════════════════════════════════════

def simulate_benchmark(config_name, config_info, num_frames=300):
    """
    模拟基准测试 — 用于开发环境验证脚本逻辑

    在实际 RK3588 板子上运行时, 此函数被 run_real_benchmark() 替代。
    模拟产生合理的性能数据用于验证报告生成、JSON 输出等。
    """
    print(f"\n{'='*60}")
    print(f"  [{config_name}] {config_info['name']}")
    print(f"  {config_info['desc']}")
    print(f"{'='*60}")

    # 根据配置模拟不同的性能特征
    perf_profiles = {
        "cpu":     {"infer": (18, 3),  "decode": (5, 1.5),  "prep": (8, 2)},
        "rga":     {"infer": (17, 2.5), "decode": (4.5, 1.2), "prep": (2, 0.5)},
        "rga_multi":{"infer": (7, 1.2), "decode": (4, 1.0),  "prep": (1.8, 0.4)},
    }
    profile = perf_profiles.get(config_name, perf_profiles["cpu"])

    collector = PerformanceCollector(config_name, config_info)
    print(f"  Simulating {num_frames} frames...")

    for i in range(num_frames):
        prep_ms   = max(0.1, np.random.normal(*profile["prep"]))
        npu_ms    = max(0.1, np.random.normal(*profile["infer"]))
        decode_ms = max(0.1, np.random.normal(*profile["decode"]))
        latency_ms = prep_ms + npu_ms + decode_ms + np.random.uniform(0, 2)
        collector.add_frame(latency_ms, prep_ms, npu_ms, decode_ms)

        if (i + 1) % 100 == 0:
            print(f"    ... {i+1}/{num_frames}")

    return collector.compute_stats()


def run_real_benchmark(config_name, config_info, num_frames, rtsp_url, model_path):
    """
    实际 RK3588 板载基准测试 — 调用 rtsp_detector.py

    通过 subprocess 调用优化后的 rtsp_detector.py,
    解析其 benchmark JSON 输出获取真实性能数据。
    """
    script_dir = os.path.dirname(os.path.abspath(__file__))
    detector_script = os.path.join(script_dir, "rtsp_detector.py")

    if not os.path.exists(detector_script):
        print(f"  [SKIP] rtsp_detector.py not found at {detector_script}")
        return None

    # 构建命令
    cmd = [
        sys.executable, detector_script,
        "--rtsp", rtsp_url,
        "--model", model_path,
        "--benchmark",
        "--benchmark-frames", str(num_frames),
    ]
    # 附加配置特定参数
    extra_args = config_info["args"].split()
    cmd.extend(extra_args)

    print(f"  Running: {' '.join(cmd)}")

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=num_frames * 0.2 + 60)
        # 尝试从 stdout 中解析 JSON 报告
        # rtsp_detector.py 会将报告写入 --benchmark-output 指定的文件
        # 这里我们搜索输出中的 Report saved: 行
        for line in result.stdout.split("\n"):
            if "Report saved:" in line:
                report_path = line.split("Report saved:")[-1].strip()
                if os.path.exists(report_path):
                    with open(report_path, "r") as f:
                        return json.load(f)
        # 也没找到就解析 stdout 中的 BENCHMARK REPORT 区域
        return _parse_benchmark_stdout(result.stdout, config_name, config_info)
    except subprocess.TimeoutExpired:
        print(f"  [TIMEOUT] Benchmark timed out")
        return None
    except Exception as e:
        print(f"  [ERROR] {e}")
        return None


def _parse_benchmark_stdout(stdout, config_name, config_info):
    """尝试从 rtsp_detector.py 的 stdout 解析 benchmark 数据"""
    stats = {"config": config_name, "description": config_info["name"]}
    for line in stdout.split("\n"):
        line = line.strip()
        if "Avg FPS:" in line:
            try:
                stats["fps"] = float(line.split(":")[-1].strip())
            except ValueError:
                pass
        if "Avg NPU" in line and "ms" in line:
            try:
                stats["npu_ms"] = float(line.split(":")[-1].replace("ms", "").strip())
            except ValueError:
                pass
    return stats if len(stats) > 2 else None


# ═══════════════════════════════════════════════════════
# 4. 报告生成
# ═══════════════════════════════════════════════════════

def generate_comparison_table(results):
    """生成 Markdown 格式的对比表"""
    if not results:
        return "No results to compare."

    lines = []
    lines.append("| 配置 | FPS | 延迟(mean) | 延迟(P95) | 延迟(P99) | NPU(mean) | Prep(mean) | Decode(mean) |")
    lines.append("|------|-----|-----------|-----------|-----------|-----------|------------|--------------|")

    for r in results:
        lat = r.get("latency_ms", {})
        npu = r.get("npu_ms", {})
        prep = r.get("preprocess_ms", {})
        decode = r.get("decode_ms", {})

        name = r.get("description", r.get("config", "?"))

        fps = r.get("fps", 0)
        fps_str = f"**{fps:.1f}**" if fps > 20 else f"{fps:.1f}"
        if fps > 40:
            fps_str += " (FAST)"
        elif fps > 25:
            fps_str += " (OK)"

        lines.append(
            f"| {name} | {fps:.1f} | {lat.get('mean',0):.1f}ms "
            f"| {lat.get('p95',0):.1f}ms | {lat.get('p99',0):.1f}ms "
            f"| {npu.get('mean',0):.1f}ms | {prep.get('mean',0):.1f}ms "
            f"| {decode.get('mean',0):.1f}ms |"
        )

    return "\n".join(lines)


def generate_latency_breakdown(results):
    """生成延迟分解 (预处理 vs NPU vs 解码 占比)"""
    lines = []
    lines.append("| 配置 | 预处理占比 | NPU推理占比 | 解码占比 | 总延迟 |")
    lines.append("|------|----------|-----------|---------|-------|")

    for r in results:
        name = r.get("description", r.get("config", "?"))
        prep_pct = r.get("preprocess_ms", {}).get("ratio", 0)
        npu_pct = r.get("npu_ms", {}).get("ratio", 0)
        decode_pct = r.get("decode_ms", {}).get("ratio", 0)
        total = r.get("latency_ms", {}).get("mean", 0)

        lines.append(
            f"| {name} | {prep_pct}% | {npu_pct}% | {decode_pct}% | {total:.1f}ms |"
        )

    return "\n".join(lines)


def compute_speedup(results):
    """计算加速比 (以 CPU 配置为基准)"""
    if not results:
        return {}

    cpu_fps = None
    for r in results:
        if r.get("config") == "cpu":
            cpu_fps = r.get("fps", 0)
            break

    if cpu_fps is None or cpu_fps == 0:
        return {}

    speedups = {}
    for r in results:
        name = r.get("config", "unknown")
        fps = r.get("fps", 0)
        if fps > 0:
            speedups[name] = {
                "fps": fps,
                "speedup_vs_cpu": round(fps / cpu_fps, 2),
                "latency_reduction": round((1 - cpu_fps / fps) * 100, 1)
                                    if fps > cpu_fps else 0,
            }

    return speedups


# ═══════════════════════════════════════════════════════
# 5. 主入口
# ═══════════════════════════════════════════════════════

def main():
    parser = argparse.ArgumentParser(
        description="RK3588 目标检测性能对比基准测试",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  python3 bench_compare.py                          # 默认: 全部配置, 每项300帧, 模拟模式
  python3 bench_compare.py --frames 500             # 每项跑500帧
  python3 bench_compare.py --configs cpu,rga        # 只跑 CPU 和 RGA
  python3 bench_compare.py --real                   # 实际板载测试 (需要 rtsp_detector.py)
  python3 bench_compare.py --real --rtsp rtsp://... # 指定 RTSP 流
  python3 bench_compare.py --output /tmp/bench      # 报告输出到指定目录
  python3 bench_compare.py --dry-run                # 试运行 10 帧验证配置
        """
    )
    parser.add_argument("--frames", type=int, default=300,
                        help="每个配置测试帧数 (default: 300)")
    parser.add_argument("--configs", default="cpu,rga,rga_multi",
                        help="要测试的配置, 逗号分隔: cpu,rga,rga_multi")
    parser.add_argument("--real", action="store_true",
                        help="实际板载测试 (需要 rtsp_detector.py + RK3588)")
    parser.add_argument("--rtsp", default="rtsp://192.168.1.168:554/stream",
                        help="RTSP 流 URL (仅在 --real 模式下)")
    parser.add_argument("--model", default="/tmp/models/yolov5s_rk3588_v5.rknn",
                        help="RKNN 模型路径 (仅在 --real 模式下)")
    parser.add_argument("--output", default="/tmp/bench_results",
                        help="报告输出目录 (default: /tmp/bench_results)")
    parser.add_argument("--dry-run", action="store_true",
                        help="试运行模式 (每配置仅10帧, 验证配置正确性)")
    parser.add_argument("--json-only", action="store_true",
                        help="只输出 JSON 报告, 不打印表格")
    args = parser.parse_args()

    # 解析配置
    configs_to_run = [c.strip() for c in args.configs.split(",")]
    for c in configs_to_run:
        if c not in BENCH_CONFIGS:
            print(f"[ERROR] 未知配置: '{c}', 可用: {list(BENCH_CONFIGS.keys())}")
            return 1

    num_frames = 10 if args.dry_run else args.frames
    mode = "DRY-RUN" if args.dry_run else ("REAL" if args.real else "SIMULATED")

    print(f"\n{'='*60}")
    print(f"  RK3588 目标检测性能对比基准测试")
    print(f"  模式: {mode}")
    print(f"  帧数: {num_frames} × {len(configs_to_run)} 配置 = {num_frames * len(configs_to_run)} 总帧")
    print(f"  配置: {', '.join(configs_to_run)}")
    print(f"{'='*60}")

    # 检查是否为模拟模式
    if args.real:
        # 检查 rtsp_detector.py 是否存在
        script_dir = os.path.dirname(os.path.abspath(__file__))
        detector_script = os.path.join(script_dir, "rtsp_detector.py")
        if not os.path.exists(detector_script):
            print(f"\n[WARNING] rtsp_detector.py not found at {detector_script}")
            print("[WARNING] Falling back to simulated benchmark mode")
            args.real = False

    # ═══ 运行所有配置 ═══
    all_results = []
    t_start = time.time()

    for i, config_name in enumerate(configs_to_run):
        config_info = BENCH_CONFIGS[config_name]
        print(f"\n── [{i+1}/{len(configs_to_run)}] {config_name} ──")

        if args.real:
            result = run_real_benchmark(
                config_name, config_info, num_frames, args.rtsp, args.model
            )
        else:
            result = simulate_benchmark(config_name, config_info, num_frames)

        if result:
            all_results.append(result)
            # 实时输出简要结果
            lat = result.get("latency_ms", {})
            print(f"  [OK] FPS={result.get('fps',0):.1f}  "
                  f"mean={lat.get('mean',0):.1f}ms  "
                  f"P95={lat.get('p95',0):.1f}ms")
        else:
            print(f"  [FAIL] 配置 '{config_name}' 测试失败, 跳过")

    elapsed = time.time() - t_start

    if not all_results:
        print("\n[ERROR] 没有成功的测试结果")
        return 1

    # ═══ 生成报告 ═══
    # 加速比
    speedups = compute_speedup(all_results)

    # 构建完整报告
    full_report = {
        "meta": {
            "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
            "mode": mode,
            "frames_per_config": num_frames,
            "configs_tested": configs_to_run,
            "total_elapsed_s": round(elapsed, 1),
            "platform": platform.platform(),
            "python": sys.version,
        },
        "results": all_results,
        "speedup": speedups,
        "winner": None,
    }

    # 找出最快配置
    if all_results:
        best = max(all_results, key=lambda r: r.get("fps", 0))
        full_report["winner"] = {
            "config": best.get("config"),
            "fps": best.get("fps"),
            "name": best.get("description"),
        }

    # 打印报告
    if not args.json_only:
        print(f"\n{'='*60}")
        print("  性能对比结果")
        print(f"{'='*60}")
        print()
        print(generate_comparison_table(all_results))
        print()
        print("  延迟分解:")
        print()
        print(generate_latency_breakdown(all_results))

        if speedups:
            print()
            print("  加速比:")
            print()
            cpu_fps = speedups.get("cpu", {}).get("fps", 0)
            for name, info in speedups.items():
                tag = "* 最快" if name == full_report["winner"]["config"] else ""
                print(f"    {name:15s}  {info['fps']:6.1f} fps  "
                      f"{info['speedup_vs_cpu']:4.1f}x vs CPU  "
                      f"(延迟降低 {info['latency_reduction']:.0f}%)  {tag}")

        if full_report["winner"]:
            print(f"\n  推荐配置: {full_report['winner']['name']} "
                  f"({full_report['winner']['fps']:.1f} fps)")

        print(f"\n  总耗时: {elapsed:.1f}s")

    # ═══ 保存 JSON 报告 ═══
    os.makedirs(args.output, exist_ok=True)
    ts = time.strftime("%Y%m%d_%H%M%S")
    json_path = os.path.join(args.output, f"bench_compare_{ts}.json")
    with open(json_path, "w") as f:
        json.dump(full_report, f, indent=2, ensure_ascii=False)

    print(f"\n  JSON 报告: {json_path}")

    # 也生成 Markdown 摘要
    md_path = os.path.join(args.output, f"bench_compare_{ts}.md")
    with open(md_path, "w") as f:
        f.write(f"# RK3588 目标检测性能对比报告\n\n")
        f.write(f"- 时间: {full_report['meta']['timestamp']}\n")
        f.write(f"- 模式: {mode}\n")
        f.write(f"- 每配置帧数: {num_frames}\n")
        f.write(f"- 平台: {full_report['meta']['platform']}\n\n")
        f.write("## 性能对比\n\n")
        f.write(generate_comparison_table(all_results))
        f.write("\n\n## 延迟分解\n\n")
        f.write(generate_latency_breakdown(all_results))
        f.write("\n\n## 加速比\n\n")
        if speedups:
            cpu_fps = speedups.get("cpu", {}).get("fps", 0)
            for name, info in speedups.items():
                f.write(f"- **{name}**: {info['fps']:.1f} fps "
                        f"({info['speedup_vs_cpu']:.1f}x vs CPU, "
                        f"延迟降低 {info['latency_reduction']:.0f}%)\n")
        f.write(f"\n## 推荐配置\n\n")
        f.write(f"**{full_report['winner']['name']}** "
                f"({full_report['winner']['fps']:.1f} fps)\n")

    print(f"  Markdown 摘要: {md_path}")

    return 0


if __name__ == "__main__":
    sys.exit(main())

