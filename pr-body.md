## Summary

Adds Python bindings for the C++ zero-copy RK3588 inference engine under `deploy/engine/python/`.

### New files

- `deploy/engine/python/bindings.cpp` - pybind11 bindings exposing `Engine` class
- `deploy/engine/python/setup.py` - `pip install` support via `CMakeBuildExt`
- `deploy/engine/python/__init__.py` - package init, re-exports `Engine`
- `deploy/engine/python/README.md` - usage docs and build instructions

### Modified files

- `deploy/engine/CMakeLists.txt` - added optional `rknn_engine_python` pybind11 module target (guarded by `BUILD_PYTHON=ON`)

### API exposed

```python
from rknn_engine import Engine

eng = Engine("config.yaml")
eng.load_model("model.rknn")
dets = eng.infer(frame_np, format="BGR888")  # zero-copy NumPy input
stats = eng.get_stats()
```

### Key design decisions

1. **Zero-copy NumPy I/O**: `py::array_t` buffer protocol passes the raw pointer directly to `Engine::Infer()` - no memory copy.
2. **Detection results as `list[dict]`**: C++ `Detection` structs converted to Python dicts with `class_id`, `class_name`, `confidence`, `bbox` keys.
3. **Stats as `dict`**: `InferenceStats` struct returned as a Python dict.
4. **Context manager**: `Engine` supports `with` blocks via `__enter__`/`__exit__`.
5. **Build flexibility**: Both `pip install .` (via `setup.py` + custom CMake build_ext) and `cmake -DBUILD_PYTHON=ON` are supported.

### Build requirements

- Python >= 3.8, NumPy >= 1.20, pybind11 >= 2.10
- CMake >= 3.16, C++17 compiler
- RK3588 native libs: `librknnrt.so`, `librga.so`, `yaml-cpp`
