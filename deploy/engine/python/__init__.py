"""
rknn-engine — Python bindings for the RK3588 zero-copy NPU inference engine.

Provides a high-level Pythonic interface to the C++ RK3588 inference engine,
supporting model loading, zero-copy NumPy inference, and performance statistics.

Typical usage:

    from rknn_engine import Engine

    # Initialize from YAML config
    engine = Engine("config/engine.yaml")

    # Load RKNN model
    engine.load_model("models/yolov5s.rknn")

    # Run inference on a NumPy frame (zero-copy)
    import numpy as np
    frame = np.random.randint(0, 256, (480, 640, 3), dtype=np.uint8)
    detections = engine.infer(frame, format="BGR888")

    # Print results
    for det in detections:
        print(f"{det['class_name']}: {det['confidence']:.2f} "
              f"at {det['bbox']}")

    # Get performance stats
    stats = engine.get_stats()
    print(f"FPS: {stats['fps']:.1f}")
"""

from rknn_engine import Engine  # noqa: F401

__all__ = ["Engine"]
__version__ = "1.0.0"
