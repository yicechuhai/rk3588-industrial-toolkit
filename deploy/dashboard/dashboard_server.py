#!/usr/bin/env python3
"""RK3588 Industrial Toolkit — Web Dashboard
FastAPI + SSE real-time monitoring panel
Usage: python3 dashboard_server.py --port 8080
"""
import asyncio, json, time, os, sys, threading, subprocess
from datetime import datetime

try:
    from fastapi import FastAPI, Request
    from fastapi.responses import HTMLResponse, StreamingResponse
    import uvicorn
except ImportError:
    subprocess.check_call([sys.executable, "-m", "pip", "install", "fastapi", "uvicorn"])
    from fastapi import FastAPI, Request
    from fastapi.responses import HTMLResponse, StreamingResponse
    import uvicorn

app = FastAPI(title="RK3588 Dashboard", version="1.0.0")

class State:
    fps = 0.0
    avg_latency_ms = 0.0
    total_frames = 0
    npu_temp_c = 0.0
    cpu_usage = 0.0
    memory_usage = 0.0
    detections = []
    detection_count = 0
    uptime_seconds = 0
    start_time = time.time()
    status = "stopped"

state = State()

def read_npu_temp():
    for p in ["/sys/class/thermal/thermal_zone0/temp", "/sys/devices/virtual/thermal/thermal_zone0/temp"]:
        try:
            with open(p) as f:
                return float(f.read().strip()) / 1000.0
        except: pass
    return 0.0

def read_cpu():
    try:
        with open("/proc/stat") as f:
            parts = f.readline().split()
        total = sum(int(x) for x in parts[1:])
        return 100.0 * (1.0 - int(parts[4])/total) if total > 0 else 0.0
    except: return 0.0

def read_mem():
    try:
        with open("/proc/meminfo") as f:
            lines = f.read()
        mem = {}
        for line in lines.split("\n"):
            if ":" in line:
                k, v = line.split(":")
                mem[k.strip()] = int(v.strip().split()[0])
        return 100.0 * (1.0 - mem.get("MemAvailable", 0)/mem.get("MemTotal", 1))
    except: return 0.0

def monitor():
    while True:
        state.npu_temp_c = read_npu_temp()
        state.cpu_usage = read_cpu()
        state.memory_usage = read_mem()
        state.uptime_seconds = int(time.time() - state.start_time)
        time.sleep(1)

async def events():
    while True:
        data = {
            "fps": round(state.fps, 1),
            "avg_latency_ms": round(state.avg_latency_ms, 2),
            "total_frames": state.total_frames,
            "npu_temp_c": round(state.npu_temp_c, 1),
            "cpu_usage": round(state.cpu_usage, 1),
            "memory_usage": round(state.memory_usage, 1),
            "detection_count": state.detection_count,
            "detections": state.detections[:10],
            "uptime_seconds": state.uptime_seconds,
            "status": state.status,
        }
        yield f"data: {json.dumps(data)}\n\n"
        await asyncio.sleep(0.5)

@app.get("/api/stats")
async def api_stats():
    return {
        "fps": round(state.fps,1), "avg_latency_ms": round(state.avg_latency_ms,2),
        "total_frames": state.total_frames, "npu_temp_c": round(state.npu_temp_c,1),
        "cpu_usage": round(state.cpu_usage,1), "memory_usage": round(state.memory_usage,1),
        "detection_count": state.detection_count, "detections": state.detections[:20],
        "uptime_seconds": state.uptime_seconds, "status": state.status,
    }

@app.post("/api/update")
async def api_update(request: Request):
    try:
        data = await request.json()
        for k in ["fps","avg_latency_ms","total_frames","status"]:
            if k in data: setattr(state, k, data[k])
        if "detections" in data:
            state.detections = data["detections"]
            state.detection_count = len(data["detections"])
        return {"ok": True}
    except: return {"ok": False}

@app.get("/api/stream")
async def api_stream():
    return StreamingResponse(events(), media_type="text/event-stream",
        headers={"Cache-Control":"no-cache","X-Accel-Buffering":"no"})

def get_html():
    html_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dashboard.html")
    with open(html_path, encoding="utf-8") as f:
        return f.read()

@app.get("/", response_class=HTMLResponse)
async def index():
    return get_html()

def main():
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=8080)
    p.add_argument("--host", default="0.0.0.0")
    args = p.parse_args()
    state.status = "running"
    threading.Thread(target=monitor, daemon=True).start()
    print(f"Dashboard: http://{args.host}:{args.port}")
    uvicorn.run(app, host=args.host, port=args.port, log_level="info")

if __name__ == "__main__":
    main()
