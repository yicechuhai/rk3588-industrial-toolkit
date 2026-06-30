/**
 * @file pybind11_wrapper.cpp
 * @brief Zero-copy NumPy I/O via pybind11 buffer protocol
 *
 * 实现 NumPy 数组零拷贝传递：
 *   1. buffer protocol 直接访问 NumPy 内存
 *   2. 自动格式校验 (shape, dtype, channels)
 *   3. Detection 结果转为 Python dict 列表
 *
 * @author RK3588 Industrial Toolkit
 * @version 1.1.0
 */

#include <pybind11/pybind11.h>
#include <pybind11/numpy.h>
#include <pybind11/stl.h>

#include "engine.h"

namespace py = pybind11;
namespace engine = rk3588::engine;

// ═══════════════════════════════════════════════════════════════════════
// 常量
// ═══════════════════════════════════════════════════════════════════════

static constexpr const char* SUPPORTED_FORMATS[] = {
    "BGR888", "RGB888", "NV12", "NV21", "GRAY8", nullptr
};

// ═══════════════════════════════════════════════════════════════════════
// 辅助函数
// ═══════════════════════════════════════════════════════════════════════

/** 检查像素格式有效性 */
static bool IsValidFormat(const std::string& fmt) {
    for (int i = 0; SUPPORTED_FORMATS[i] != nullptr; ++i) {
        if (fmt == SUPPORTED_FORMATS[i]) return true;
    }
    return false;
}

/** InferenceStats -> Python dict */
static py::dict StatsToDict(const engine::InferenceStats& stats) {
    py::dict d;
    d["fps"]            = stats.fps;
    d["avg_latency_ms"] = stats.avg_latency_ms;
    d["min_latency_ms"] = stats.min_latency_ms;
    d["max_latency_ms"] = stats.max_latency_ms;
    d["total_frames"]   = static_cast<uint64_t>(stats.total_frames);
    d["preprocess_ms"]  = stats.preprocess_ms;
    d["inference_ms"]   = stats.inference_ms;
    d["postprocess_ms"] = stats.postprocess_ms;
    return d;
}

/** Detection -> Python dict */
static py::dict DetectionToDict(const engine::Detection& det) {
    py::dict d;
    d["class_id"]   = det.class_id;
    d["class_name"] = det.class_name;
    d["confidence"] = det.confidence;
    d["bbox"]       = py::make_tuple(det.x1, det.y1, det.x2, det.y2);
    return d;
}

// ═══════════════════════════════════════════════════════════════════════
// 输入校验器
// ═══════════════════════════════════════════════════════════════════════

/**
 * @brief 校验 NumPy 输入帧的 shape / dtype / format 兼容性
 *
 * @param buf     buffer_info
 * @param format  像素格式字符串
 * @throws std::runtime_error 不符合预期时
 */
static void ValidateInputFrame(const py::buffer_info& buf,
                               const std::string& format) {
    // 检查 dtype
    if (buf.format != py::format_descriptor<uint8_t>::format()) {
        throw std::runtime_error(
            "Input array must have dtype=uint8, got dtype=" + buf.format);
    }

    // 检查维度
    if (buf.ndim < 2) {
        throw std::runtime_error(
            "Input array must have at least 2 dimensions [H, W] or [H, W, C]");
    }

    int height   = static_cast<int>(buf.shape[0]);
    int width    = static_cast<int>(buf.shape[1]);
    int channels = (buf.ndim >= 3) ? static_cast<int>(buf.shape[2]) : 1;

    // 尺寸合理性
    if (height <= 0 || width <= 0) {
        throw std::runtime_error(
            "Input dimensions must be positive, got " +
            std::to_string(width) + "x" + std::to_string(height));
    }

    // 通道校验
    bool is_rgb = (format == "RGB888" || format == "RGB");
    bool is_bgr = (format == "BGR888" || format == "BGR");
    if ((is_rgb || is_bgr) && channels != 3) {
        throw std::runtime_error(
            "Format " + format + " expects 3 channels, got " +
            std::to_string(channels));
    }

    // GRAY8 单通道
    if (format == "GRAY8" && channels != 1) {
        throw std::runtime_error(
            "Format GRAY8 expects 1 channel, got " +
            std::to_string(channels));
    }

    // NV12 / NV21: H*1.5 高度
    if ((format == "NV12" || format == "NV21")) {
        if (channels != 1) {
            throw std::runtime_error(
                "Format " + format + " expects single-channel packed array, got " +
                std::to_string(channels));
        }
        uint32_t expected_h = static_cast<uint32_t>(height * 3 / 2);
        if (buf.shape[0] != static_cast<py::ssize_t>(expected_h)) {
            throw std::runtime_error(
                "Format " + format + " expects height=" +
                std::to_string(expected_h) + " (H*1.5), got " +
                std::to_string(height));
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Pybind11 Module
// ═══════════════════════════════════════════════════════════════════════

PYBIND11_MODULE(rknn_engine, m) {
    m.doc() = "RK3588 zero-copy NPU inference engine -- pybind11 NumPy bindings";

    // ── 异常转换 ──
    py::register_exception_translator([](std::exception_ptr p) {
        try {
            if (p) std::rethrow_exception(p);
        } catch (const std::runtime_error& e) {
            PyErr_SetString(PyExc_RuntimeError, e.what());
        } catch (const std::invalid_argument& e) {
            PyErr_SetString(PyExc_ValueError, e.what());
        } catch (const std::exception& e) {
            PyErr_SetString(PyExc_Exception, e.what());
        }
    });

    // ── Engine 类 ──
    py::class_<engine::Engine>(m, "Engine", R"doc(
        RK3588 NPU Engine with zero-copy NumPy I/O.

        Example:
            >>> from rknn_engine import Engine
            >>> eng = Engine("config/engine.yaml")
            >>> eng.load_model("models/yolov5s.rknn")
            >>> # Zero-copy: NumPy uint8[H,W,3] BGR/RGB
            >>> results = eng.infer(frame_np, format="BGR888")
            >>> stats = eng.get_stats()
            >>> print(stats["fps"])
    )doc")

        .def(py::init<const std::string&>(),
             py::arg("config_path"),
             "Construct engine from YAML config.")

        // ── Context manager ──
        .def("__enter__", [](engine::Engine& self) -> engine::Engine& {
            return self;
        })
        .def("__exit__", [](engine::Engine& self, py::object, py::object,
                            py::object) {})

        // ── load_model ──
        .def("load_model", &engine::Engine::LoadModel,
             py::arg("model_path"),
             "Load an .rknn model. Returns True on success.")

        // ── infer (zero-copy) ──
        .def("infer",
             [](engine::Engine& self,
                py::array_t<uint8_t,
                            py::array::c_style | py::array::forcecast> frame,
                const std::string& format) -> py::list {
                 py::buffer_info buf = frame.request();
                 ValidateInputFrame(buf, format);

                 int height = static_cast<int>(buf.shape[0]);
                 int width  = static_cast<int>(buf.shape[1]);
                 auto* data = static_cast<const uint8_t*>(buf.ptr);

                 std::vector<engine::Detection> detections =
                     self.Infer(data, width, height, format);

                 py::list result;
                 for (const auto& det : detections) {
                     result.append(DetectionToDict(det));
                 }
                 return result;
             },
             py::arg("frame"),
             py::arg("format") = "BGR888",
             "Zero-copy inference. Returns list[dict].")

        // ── infer_batch ──
        .def("infer_batch",
             [](engine::Engine& self,
                py::array_t<uint8_t,
                            py::array::c_style | py::array::forcecast> frames,
                const std::string& format) -> py::list {
                 py::buffer_info buf = frames.request();
                 if (buf.format != py::format_descriptor<uint8_t>::format()) {
                     throw std::runtime_error("dtype must be uint8");
                 }
                 if (buf.ndim != 4) {
                     throw std::runtime_error("Batch needs [N,H,W,C]");
                 }

                 int batch    = static_cast<int>(buf.shape[0]);
                 int height   = static_cast<int>(buf.shape[1]);
                 int width    = static_cast<int>(buf.shape[2]);
                 auto* data   = static_cast<const uint8_t*>(buf.ptr);

                 py::list batch_results;
                 for (int i = 0; i < batch; ++i) {
                     const uint8_t* fp = data +
                         static_cast<size_t>(i) * height * width * 3;
                     auto dets = self.Infer(fp, width, height, format);
                     py::list fd;
                     for (const auto& d : dets) fd.append(DetectionToDict(d));
                     batch_results.append(fd);
                 }
                 return batch_results;
             },
             py::arg("frames"),
             py::arg("format") = "BGR888",
             "Batch inference on [N,H,W,C] array. Returns list[list[dict]].")

        // ── get_stats ──
        .def("get_stats",
             [](const engine::Engine& self) -> py::dict {
                 return StatsToDict(self.GetStats());
             },
             "Get performance statistics dict.")

        // ── reset_stats ──
        .def("reset_stats", &engine::Engine::ResetStats,
             "Reset all performance counters.")

        // ── is_ready ──
        .def("is_ready", &engine::Engine::IsReady,
             "Check engine readiness.");

    // ── 模块常量 ──
    m.attr("__version__") = "1.1.0";
    m.attr("SUPPORTED_FORMATS") =
        py::make_tuple("BGR888", "RGB888", "NV12", "NV21", "GRAY8");
}
