# rknn-engine — Python Bindings

Python bindings for the RK3588 zero-copy NPU inference engine.

Provides a Pythonic interface to the C++ `Engine` class, supporting:

- **Zero-copy NumPy I/O** — pass NumPy arrays directly to the NPU without copying
- **Model loading** — load `.rknn` models
- **Inference** — run YOLO detection with a single function call
- **Performance stats** — FPS, latency breakdown

## Quick Start

```python
import numpy as np
from rknn_engine import Engine

# Initialize from YAML config
engine = Engine("config/engine.yaml")

# Load model
engine.load_model("models/yolov5s.rknn")

# Run inference (zero-copy: NumPy → NPU)
frame = np.random.randint(0, 256, (480, 640, 3), dtype=np.uint8)
detections = engine.infer(frame, format="BGR888")

for det in detections:
    print(f"{det['class_name']}: {det['confidence']:.2f} "
          f"at {det['bbox']}")

# Get stats
stats = engine.get_stats()
print(f"FPS: {stats['fps']:.1f}, "
      f"Latency: {stats['avg_latency_ms']:.1f} ms")
```

## API Reference

### `Engine(config_path: str)`

Construct the engine. `config_path` is a YAML file path.

#### `load_model(model_path: str) -> bool`

Load an RKNN model file.

#### `infer(frame: np.ndarray, format: str = "BGR888") -> list[dict]`

Run inference on a single frame. The NumPy array is passed **zero-copy** to the engine.

- `frame`: `uint8` array of shape `[H, W]` or `[H, W, C]`
- `format`: `"BGR888"` (default), `"RGB888"`, or `"NV12"`
- Returns: list of detection dicts with keys `class_id`, `class_name`, `confidence`, `bbox` (tuple `x1, y1, x2, y2`)

#### `get_stats() -> dict`

Get inference performance statistics.

Returns dict with keys: `fps`, `avg_latency_ms`, `min_latency_ms`, `max_latency_ms`, `total_frames`, `preprocess_ms`, `inference_ms`, `postprocess_ms`.

#### `reset_stats()`

Reset all performance counters.

#### `is_ready() -> bool`

Check if the engine is initialized and ready.

## Building

### On-device (RK3588)

```bash
cd deploy/engine/python
pip install .
```

### Cross-compilation

```bash
export RKNN_TOOLCHAIN=/path/to/aarch64-linux-gnu
cd deploy/engine/python
pip install .
```

### Via CMake

```bash
cd deploy/engine
mkdir build && cd build
cmake .. -DBUILD_PYTHON=ON
make rknn_engine_python -j4
```

## Dependencies

- Python >= 3.8
- NumPy >= 1.20
- pybind11 >= 2.10
- CMake >= 3.16
- C++17 compiler (GCC >= 8 / Clang >= 10)
- RK3588 native libraries: `librknnrt.so`, `librga.so`, `yaml-cpp`
