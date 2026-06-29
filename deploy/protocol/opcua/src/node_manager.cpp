#include "opcua_server.h"

#include <cstdio>
#include <cstring>

namespace rk3588 {
namespace protocol {
namespace opcua {

namespace {

UA_Variant MakeFloatVariant(float value) {
  UA_Variant v;
  UA_Variant_init(&v);
  UA_Float* f = UA_Float_new();
  *f = value;
  UA_Variant_setScalarCopy(&v, f, &UA_TYPES[UA_TYPES_FLOAT]);
  UA_Float_delete(f);
  return v;
}

UA_Variant MakeUInt32Variant(uint32_t value) {
  UA_Variant v;
  UA_Variant_init(&v);
  UA_UInt32* u = UA_UInt32_new();
  *u = value;
  UA_Variant_setScalarCopy(&v, u, &UA_TYPES[UA_TYPES_UINT32]);
  UA_UInt32_delete(u);
  return v;
}

UA_Variant MakeUInt16Variant(uint16_t value) {
  UA_Variant v;
  UA_Variant_init(&v);
  UA_UInt16* u = UA_UInt16_new();
  *u = value;
  UA_Variant_setScalarCopy(&v, u, &UA_TYPES[UA_TYPES_UINT16]);
  UA_UInt16_delete(u);
  return v;
}

UA_Variant MakeStringVariant(const char* value) {
  UA_Variant v;
  UA_Variant_init(&v);
  UA_String s = UA_STRING_ALLOC(value);
  UA_Variant_setScalarCopy(&v, &s, &UA_TYPES[UA_TYPES_STRING]);
  UA_String_clear(&s);
  return v;
}

}  // namespace

void OpcuaServer::AddObjectFolder(UA_NodeId parent, const char* name,
                                  UA_UInt16 ns_idx, UA_NodeId* out_node_id) {
  UA_ObjectAttributes attr = UA_ObjectAttributes_default;
  attr.displayName =
      UA_LOCALIZEDTEXT(const_cast<char*>("en-US"), const_cast<char*>(name));
  UA_Server_addObjectNode(
      server_, UA_NODEID_NULL,
      parent,
      UA_NODEID_NUMERIC(0, UA_NS0ID_ORGANIZES),
      UA_QUALIFIEDNAME(ns_idx, const_cast<char*>(name)),
      UA_NODEID_NUMERIC(0, UA_NS0ID_FOLDERTYPE),
      attr, nullptr, out_node_id);
}

void OpcuaServer::AddVariableNode(UA_NodeId parent, const char* name,
                                  UA_UInt16 ns_idx, const UA_Variant& value,
                                  UA_NodeId* out_node_id) {
  UA_VariableAttributes attr = UA_VariableAttributes_default;
  attr.displayName =
      UA_LOCALIZEDTEXT(const_cast<char*>("en-US"), const_cast<char*>(name));
  attr.accessLevel = UA_ACCESSLEVELMASK_READ | UA_ACCESSLEVELMASK_WRITE;
  attr.value = value;

  UA_Server_addVariableNode(
      server_, UA_NODEID_NULL,
      parent,
      UA_NODEID_NUMERIC(0, UA_NS0ID_ORGANIZES),
      UA_QUALIFIEDNAME(ns_idx, const_cast<char*>(name)),
      UA_NODEID_NUMERIC(0, UA_NS0ID_BASEDATAVARIABLETYPE),
      attr, nullptr, out_node_id);
}

void OpcuaServer::BuildNodeModel() {
  UA_UInt16 ns_idx =
      UA_Server_addNamespace(server_, "http://rk3588-toolkit/opcua");

  // ===================================================================
  // Root / Objects / RK3588_Industrial
  // ===================================================================
  UA_NodeId rk3588_folder;
  AddObjectFolder(UA_NODEID_NUMERIC(0, UA_NS0ID_OBJECTSFOLDER),
                  "RK3588_Industrial", ns_idx, &rk3588_folder);

  // ===================================================================
  // SystemStatus
  // ===================================================================
  UA_NodeId sys_folder;
  AddObjectFolder(rk3588_folder, "SystemStatus", ns_idx, &sys_folder);

  AddVariableNode(sys_folder, "CPU_Usage", ns_idx,
                  MakeFloatVariant(0.0F), &cpu_usage_node_);
  AddVariableNode(sys_folder, "Memory_Usage", ns_idx,
                  MakeFloatVariant(0.0F), &memory_usage_node_);
  AddVariableNode(sys_folder, "NPU_Temperature", ns_idx,
                  MakeFloatVariant(0.0F), &npu_temp_node_);
  AddVariableNode(sys_folder, "Inference_FPS", ns_idx,
                  MakeFloatVariant(0.0F), &fps_node_);

  // ===================================================================
  // InferenceResults
  // ===================================================================
  UA_NodeId infer_folder;
  AddObjectFolder(rk3588_folder, "InferenceResults", ns_idx, &infer_folder);

  AddVariableNode(infer_folder, "DetectionCount", ns_idx,
                  MakeUInt32Variant(0), &detection_count_node_);

  // Detections[] 文件夹
  UA_NodeId detections_folder;
  AddObjectFolder(infer_folder, "Detections", ns_idx, &detections_folder);

  detection_slots_.reserve(kMaxDetections);

  for (int i = 0; i < kMaxDetections; ++i) {
    char name_buf[32];
    std::snprintf(name_buf, sizeof(name_buf), "Detection_%d", i);

    UA_NodeId slot_folder;
    AddObjectFolder(detections_folder, name_buf, ns_idx, &slot_folder);

    DetectionSlotNodes slot;
    UA_NodeId_init(&slot.class_id);
    UA_NodeId_init(&slot.confidence);
    UA_NodeId_init(&slot.bbox_x);
    UA_NodeId_init(&slot.bbox_y);
    UA_NodeId_init(&slot.bbox_w);
    UA_NodeId_init(&slot.bbox_h);

    AddVariableNode(slot_folder, "ClassID", ns_idx,
                    MakeUInt16Variant(0), &slot.class_id);
    AddVariableNode(slot_folder, "Confidence", ns_idx,
                    MakeFloatVariant(0.0F), &slot.confidence);
    AddVariableNode(slot_folder, "BBox_X", ns_idx,
                    MakeFloatVariant(0.0F), &slot.bbox_x);
    AddVariableNode(slot_folder, "BBox_Y", ns_idx,
                    MakeFloatVariant(0.0F), &slot.bbox_y);
    AddVariableNode(slot_folder, "BBox_W", ns_idx,
                    MakeFloatVariant(0.0F), &slot.bbox_w);
    AddVariableNode(slot_folder, "BBox_H", ns_idx,
                    MakeFloatVariant(0.0F), &slot.bbox_h);

    detection_slots_.push_back(slot);
  }

  // ===================================================================
  // Configuration
  // ===================================================================
  UA_NodeId config_folder;
  AddObjectFolder(rk3588_folder, "Configuration", ns_idx, &config_folder);

  AddVariableNode(config_folder, "ModelName", ns_idx,
                  MakeStringVariant("yolov5s"), &model_name_node_);
  AddVariableNode(config_folder, "InputResolution", ns_idx,
                  MakeStringVariant("640x640"), &input_resolution_node_);
}

}  // namespace opcua
}  // namespace protocol
}  // namespace rk3588
