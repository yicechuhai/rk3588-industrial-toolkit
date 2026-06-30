# Changelog - RK3588 Industrial AI Vision Toolkit

## v3.0.0 (2026-06-30) - Threaded Pipeline
### Added
- Threaded pipeline architecture (capture + inference decoupled)
- Ring buffer (4 slots) for zero-copy frame passing
- Pre-allocated numpy buffers for preprocessing
- RGA hardware acceleration support (librga.so integration)
### Changed
- Switched to rknpu2 official YOLOv5s model (v1.5.2 runtime compatible)
- NPU inference: 108ms -> 21.7ms (5x faster)
- End-to-end FPS: 8.2 -> 25.7 (3.1x improvement)
- Memory usage: 480MB -> 393MB (-18%)
### Fixed
- C++ pipeline_runner RTSP soft decode fallback (CAP_FFMPEG -> CAP_ANY)
- Engine model path resolution from YAML config

## v2.0.0 (2026-06-29) - Production Pipeline
### Added
- Production pipeline (prod_pipeline.py) with Dashboard API integration
- systemd auto-start services (dashboard + pipeline + modbus)
- Benchmark reporting tool (benchmark_report.sh)
- Model manager script (model_manager.sh)
- CI/CD pipeline (.github/workflows/ci.yml)
### Changed
- Pipeline config unified to YAML (engine.yaml)
- Dashboard SSE real-time stats endpoint

## v1.0.0 (2026-06-28) - Initial Release
### Added
- C++ Zero-Copy Inference Engine (libengine.so)
- Python bindings via pybind11 (rknn_engine)
- Modbus TCP Server (libmodbus)
- OPC UA Server (open62541)
- Web Dashboard (FastAPI + SSE)
- YOLOv5s NPU model conversion
- RTSP camera capture support
