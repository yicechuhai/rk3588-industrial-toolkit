/**
 * @file model_loader.cpp
 * @brief RKNN 模型加载器实现
 *
 * 封装 Rockchip RKNN API:
 *   - rknn_init()        加载模型
 *   - rknn_query()       查询输入输出信息
 *   - rknn_set_core_mask() 核心分配
 *   - rknn_destroy()     释放资源
 */

#include "model_loader.h"

#include <cstring>
#include <fstream>
#include <stdexcept>
#include <vector>

#include <rknn/rknn_api.h>

namespace rk3588 {
namespace engine {

// ============================================================================
// PIMPL 实现结构
// ============================================================================

struct ModelLoader::Impl {
  rknn_context ctx = 0;
  bool loaded = false;
  ModelIOInfo io_info;
  NpuConfig npu_config;
};

// ============================================================================
// 构造 / 析构
// ============================================================================

ModelLoader::ModelLoader() : impl_(std::make_unique<Impl>()) {}

ModelLoader::~ModelLoader() {
  Release();
}

// ============================================================================
// 模型加载
// ============================================================================

bool ModelLoader::Load(const std::string& model_path,
                       const NpuConfig& npu_config) {
  if (impl_->loaded) {
    Release();
  }

  impl_->npu_config = npu_config;

  // 读取模型文件到内存
  std::ifstream file(model_path, std::ios::binary | std::ios::ate);
  if (!file.is_open()) {
    return false;
  }

  std::streamsize file_size = file.tellg();
  file.seekg(0, std::ios::beg);

  std::vector<uint8_t> model_data(file_size);
  if (!file.read(reinterpret_cast<char*>(model_data.data()), file_size)) {
    return false;
  }
  file.close();

  // 初始化 RKNN
  int ret = rknn_init(&impl_->ctx, model_data.data(),
                      static_cast<uint32_t>(file_size), 0, nullptr);
  if (ret < 0) {
    impl_->ctx = 0;
    return false;
  }

  // 设置 NPU 核心掩码
  ret = rknn_set_core_mask(impl_->ctx, impl_->npu_config.core_mask);
  if (ret < 0) {
    rknn_destroy(impl_->ctx);
    impl_->ctx = 0;
    return false;
  }

  // 查询输入输出信息
  QueryIOInfo(impl_->ctx, impl_->io_info);

  impl_->loaded = true;
  return true;
}

// ============================================================================
// 查询模型 IO 信息
// ============================================================================

void ModelLoader::QueryIOInfo(rknn_context ctx, ModelIOInfo& io_info) {
  // 查询输入输出数量
  rknn_input_output_num io_num;
  int ret = rknn_query(ctx, RKNN_QUERY_IN_OUT_NUM, &io_num, sizeof(io_num));
  if (ret < 0) {
    return;
  }

  io_info.num_inputs = io_num.n_input;
  io_info.num_outputs = io_num.n_output;

  // 查询每个输入的详细信息
  io_info.inputs.clear();
  for (uint32_t i = 0; i < io_num.n_input; ++i) {
    rknn_tensor_attr attr;
    attr.index = i;
    ret = rknn_query(ctx, RKNN_QUERY_INPUT_ATTR, &attr, sizeof(attr));
    if (ret < 0) continue;

    TensorInfo info;
    info.index = attr.index;
    info.name = std::string(reinterpret_cast<const char*>(attr.name));
    info.n_dims = attr.n_dims;
    info.size = attr.size;
    info.type = attr.type;
    info.fmt = attr.fmt;
    info.scale = attr.scale;
    info.zp = attr.zp;
    std::memcpy(info.dims, attr.dims, sizeof(info.dims));
    io_info.inputs.push_back(info);
  }

  // 查询每个输出的详细信息
  io_info.outputs.clear();
  for (uint32_t i = 0; i < io_num.n_output; ++i) {
    rknn_tensor_attr attr;
    attr.index = i;
    ret = rknn_query(ctx, RKNN_QUERY_OUTPUT_ATTR, &attr, sizeof(attr));
    if (ret < 0) continue;

    TensorInfo info;
    info.index = attr.index;
    info.name = std::string(reinterpret_cast<const char*>(attr.name));
    info.n_dims = attr.n_dims;
    info.size = attr.size;
    info.type = attr.type;
    info.fmt = attr.fmt;
    info.scale = attr.scale;
    info.zp = attr.zp;
    std::memcpy(info.dims, attr.dims, sizeof(info.dims));
    io_info.outputs.push_back(info);
  }
}

// ============================================================================
// 公共接口
// ============================================================================

ModelIOInfo ModelLoader::GetIOInfo() const {
  return impl_->io_info;
}

rknn_context ModelLoader::GetContext() const {
  return impl_->ctx;
}

bool ModelLoader::SetCoreMask(uint32_t core_mask) {
  if (!impl_->loaded) return false;
  int ret = rknn_set_core_mask(impl_->ctx, core_mask);
  if (ret == 0) {
    impl_->npu_config.core_mask = core_mask;
    return true;
  }
  return false;
}

bool ModelLoader::IsLoaded() const {
  return impl_->loaded;
}

void ModelLoader::Release() {
  if (impl_->ctx != 0) {
    rknn_destroy(impl_->ctx);
    impl_->ctx = 0;
  }
  impl_->loaded = false;
  impl_->io_info = ModelIOInfo{};
}

}  // namespace engine
}  // namespace rk3588
