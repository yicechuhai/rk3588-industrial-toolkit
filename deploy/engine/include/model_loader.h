#pragma once

/**
 * @file model_loader.h
 * @brief RKNN 模型加载器 — 封装 RKNN API 的加载与查询
 *
 * 负责加载 .rknn 模型文件、查询输入输出张量信息、
 * 配置 NPU 核心分配策略。
 *
 * @author RK3588 Industrial Toolkit
 * @version 1.0.0
 */

#include <cstdint>
#include <rknn/rknn_api.h>
#include <string>
#include <memory>
#include <vector>

// RKNN API 前向声明
typedef void* rknn_context;

namespace rk3588 {
namespace engine {

/** @brief 张量信息描述 */
struct TensorInfo {
  uint32_t index;          ///< 张量索引
  std::string name;        ///< 张量名称
  uint32_t n_dims;         ///< 维度数
  uint32_t dims[4];        ///< 各维度大小 [n,h,w,c] 或 [n,c,h,w]
  uint32_t size;           ///< 张量总字节数
  uint32_t type;           ///< 数据类型 (e.g. RKNN_TENSOR_UINT8)
  uint32_t fmt;            ///< 数据排布格式 (e.g. RKNN_TENSOR_NHWC)
  float scale;             ///< 量化缩放因子
  uint32_t zp;             ///< 量化零点
  bool is_dynamic;         ///< 是否为动态形状
};

/** @brief 模型输入输出信息汇总 */
struct ModelIOInfo {
  std::vector<TensorInfo> inputs;   ///< 输入张量列表
  std::vector<TensorInfo> outputs;  ///< 输出张量列表
  uint32_t num_inputs;              ///< 输入数量
  uint32_t num_outputs;             ///< 输出数量
};

/** @brief NPU 核心配置 */
struct NpuConfig {
  uint32_t core_mask = 0x7;  ///< NPU 核心掩码 (bit0=Core0, bit1=Core1, bit2=Core2)
  bool auto_freq = true;     ///< 是否自动调频
  uint32_t freq_mhz = 1000;  ///< 手动设置频率 (MHz)
};

/**
 * @class ModelLoader
 * @brief RKNN 模型加载与管理
 *
 * 封装 rknn_init / rknn_query / rknn_destroy 等底层 API。
 * 支持 DMA-BUF 零拷贝内存分配 (rknn_create_memory)。
 *
 * 使用示例:
 * @code
 *   ModelLoader loader;
 *   loader.Load("models/yolov5s.rknn", {.core_mask = 0x7});
 *   auto io_info = loader.GetIOInfo();
 *   auto* ctx = loader.GetContext();
 * @endcode
 */
class ModelLoader {
 public:
  ModelLoader();
  ~ModelLoader();

  // 禁止拷贝
  ModelLoader(const ModelLoader&) = delete;
  ModelLoader& operator=(const ModelLoader&) = delete;

  /**
   * @brief 加载 RKNN 模型文件
   * @param model_path .rknn 模型文件路径
   * @param npu_config NPU 核心配置
   * @return 成功返回 true
   */
  bool Load(const std::string& model_path, const NpuConfig& npu_config = {});

  /**
   * @brief 获取模型输入输出信息
   * @return ModelIOInfo 结构体
   */
  ModelIOInfo GetIOInfo() const;

  /**
   * @brief 获取 RKNN 上下文句柄
   * @return rknn_context 原生句柄（用于 rknn_run 等调用）
   */
  rknn_context GetContext() const;

  /**
   * @brief 设置 NPU 核心掩码
   * @param core_mask NPU 核心掩码 (0x1 ~ 0x7)
   * @return 成功返回 true
   */
  bool SetCoreMask(uint32_t core_mask);

  /**
   * @brief 检查模型是否已加载
   * @return 已加载返回 true
   */
  bool IsLoaded() const;

  /**
   * @brief 释放模型资源
   */
  void Release();

 private:
  static void QueryIOInfo(rknn_context ctx, ModelIOInfo& io_info);
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace engine
}  // namespace rk3588
