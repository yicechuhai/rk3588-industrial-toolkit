/**
 * @file bindings.cpp
 * @brief pybind11 Python bindings for RK3588 zero-copy inference engine
 *
 * Exposes Engine class with zero-copy NumPy array I/O.
 *
 * Build with:
 *   python setup.py build_ext --inplace
 *
 * @author RK3588 Industrial Toolkit
 * @version 1.0.0
 */

#include <pybind11/pybind11.h>
#include <pybind11/numpy.h>
#include <pybind11/stl.h>

#include "engine.h"

namespace py = pybind11;
namespace engine = rk3588::engine;

// ── Helper: convert InferenceStats to Python dict ──
py::dict StatsToDict(const engine::InferenceStats& stats) {
  py::dict d;
  d["fps"]              = stats.fps;
  d["avg_latency_ms"]   = stats.avg_latency_ms;
  d["min_latency_ms"]   = stats.min_latency_ms;
  d["max_latency_ms"]   = stats.max_latency_ms;
  d["total_frames"]     = stats.total_frames;
  d["preprocess_ms"]    = stats.preprocess_ms;
  d["inference_ms"]     = stats.inference_ms;
  d["postprocess_ms"]   = stats.postprocess_ms;
  return d;
}

// ── Helper: convert Detection to Python dict ──
py::dict DetectionToDict(const engine::Detection& det) {
  py::dict d;
  d["class_id"]   = det.class_id;
  d["class_name"] = det.class_name;
  d["confidence"] = det.confidence;
  d["bbox"]       = py::make_tuple(det.x1, det.y1, det.x2, det.y2);
  return d;
}

// ── Pybind11 module ──
PYBIND11_MODULE(rknn_engine, m) {
  m.doc() = "RK3588 zero-copy NPU inference engine bindings";

  // ── Exception translations ──
  py::register_exception_translator([](std::exception_ptr p) {
    try {
      if (p) std::rethrow_exception(p);
    } catch (const std::runtime_error& e) {
      PyErr_SetString(PyExc_RuntimeError, e.what());
    }
  });

  // ── Engine class ──
  py::class_<engine::Engine>(m, "Engine", R"(
    RK3588 zero-copy NPU inference engine.

    Integrates model loading, RGA hardware-accelerated preprocessing,
    NPU inference, and YOLO post-processing into a single pipeline.

    Examples:
        >>> from rknn_engine import Engine
        >>> eng = Engine("config/engine.yaml")
        >>> eng.load_model("models/yolov5s.rknn")
        >>> # NumPy array uint8[H, W, 3] in RGB/BGR order
        >>> results = eng.infer(frame_np, format="BGR888")
        >>> stats = eng.get_stats()
        >>> print(stats["fps"])
  )")

      // ── Construction / destruction ──
      .def(py::init<const std::string&>(),
           py::arg("config_path"),
           R"(Construct the engine from a YAML configuration file.

           Args:
               config_path: Path to the YAML configuration file.

           Raises:
               RuntimeError: If config parsing fails.
           )")

      // ── Context manager support ──
      .def("__enter__", [](engine::Engine& self) -> engine::Engine& {
        return self;
      })
      .def("__exit__", [](engine::Engine& self, py::object, py::object,
                          py::object) {
        // Engine destructor handles cleanup; nothing extra needed.
      })

      // ── load_model ──
      .def("load_model", &engine::Engine::LoadModel,
           py::arg("model_path"),
           R"(Load an RKNN model.

           Args:
               model_path: Path to the .rknn model file.

           Returns:
               True if the model was loaded successfully.

           Raises:
               RuntimeError: On internal failure.
           )")

      // ── infer (zero-copy NumPy) ──
      .def("infer", [](engine::Engine& self,
                       py::array_t<uint8_t, py::array::c_style | py::array::forcecast> frame,
                       const std::string& format) -> py::list {
        // Validate input array
        py::buffer_info buf = frame.request();
        if (buf.ndim < 2) {
          throw std::runtime_error(
              "Input array must have at least 2 dimensions [H, W] or [H, W, C]");
        }

        int height   = static_cast<int>(buf.shape[0]);
        int width    = static_cast<int>(buf.shape[1]);
        int channels = (buf.ndim >= 3) ? static_cast<int>(buf.shape[2]) : 1;

        // Basic sanity: if format suggests 3-channel, verify
        if ((format == "RGB888" || format == "RGB" ||
             format == "BGR888" || format == "BGR") && channels != 3) {
          throw std::runtime_error(
              "Format " + format + " expects 3 channels, got " +
              std::to_string(channels));
        }
        if (format == "NV12" && channels != 1) {
          // NV12 is packed YUV — the array is [H*1.5, W] single channel;
          // allow it through.
        }

        // Zero-copy: pass the raw pointer from NumPy's buffer directly
        auto* data = static_cast<const uint8_t*>(buf.ptr);

        std::vector<engine::Detection> detections =
            self.Infer(data, width, height, format);

        // Convert result to Python list of dicts
        py::list result;
        for (const auto& det : detections) {
          result.append(DetectionToDict(det));
        }
        return result;
      },
           py::arg("frame"),
           py::arg("format") = "BGR888",
           R"(Run inference on a single frame with zero-copy NumPy input.

           The input array is passed directly to the engine without copying,
           using the underlying C-style buffer pointer.

           Args:
               frame: NumPy array of shape [H, W] or [H, W, C], dtype uint8.
                      Supported formats: BGR888, RGB888, NV12.
               format: Pixel format string. Defaults to "BGR888".

           Returns:
               List of detection dicts, each with keys:
                   class_id, class_name, confidence, bbox (x1, y1, x2, y2)

           Raises:
               RuntimeError: On invalid array shape or inference failure.
           )")

      // ── get_stats ──
      .def("get_stats", [](const engine::Engine& self) -> py::dict {
        return StatsToDict(self.GetStats());
      }, R"(Get inference performance statistics.

           Returns:
               dict with keys:
                   fps, avg_latency_ms, min_latency_ms, max_latency_ms,
                   total_frames, preprocess_ms, inference_ms, postprocess_ms
           )")

      // ── reset_stats ──
      .def("reset_stats", &engine::Engine::ResetStats,
           R"(Reset all performance counters to zero.)")

      // ── is_ready ──
      .def("is_ready", &engine::Engine::IsReady,
           R"(Check whether the engine is fully initialized and ready.

           Returns:
               True if a model is loaded and the engine is ready for inference.
           )");

  // ── Module-level helpers (optional, for debugging) ──
  m.def("_detection_to_dict", &DetectionToDict,
        "Convert a C++ Detection struct to a Python dict (internal).");
}
