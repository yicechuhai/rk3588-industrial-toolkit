# ============================================================================
# RK3588 零拷贝推理引擎 — CMake 构建配置
# ============================================================================
# 生成产物:
#   - libengine.so         共享库 (供 Python/C++ SDK 调用)
#   - demo_inference       演示可执行文件
#
# 依赖:
#   - librknnrt.so         RKNN Runtime (NPU 推理)
#   - librga.so            RGA 硬件加速 (图像缩放/颜色转换)
#   - yaml-cpp             YAML 配置解析
#
# 编译要求:
#   - C++17 标准
#   - aarch64-linux-gnu 交叉编译 或 RK3588 板载编译
# ============================================================================

cmake_minimum_required(VERSION 3.16)
project(rk3588_engine VERSION 1.0.0 LANGUAGES CXX)

# ── C++17 标准 ──
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# ── 编译选项 ──
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(CMAKE_BUILD_TYPE STREQUAL "Release")
    add_compile_options(-O3 -DNDEBUG -march=armv8.2-a+dotprod+fp16)
else()
    add_compile_options(-O2 -g -DDEBUG)
endif()

# 平台警告选项
add_compile_options(
    -Wall
    -Wextra
    -Wpedantic
    -Wno-unused-parameter
    -Wno-missing-field-initializers
)

# ── 查找依赖库 ──

# RKNN Runtime
find_library(RKNNRT_LIB rknnrt
    PATHS
        /usr/lib
        /usr/lib/aarch64-linux-gnu
        /usr/local/lib
        /opt/rk3588-toolkit/lib
    REQUIRED
)
message(STATUS "Found librknnrt: ${RKNNRT_LIB}")

# RGA (Rockchip Graphics Accelerator)
find_library(RGA_LIB rga
    PATHS
        /usr/lib
        /usr/lib/aarch64-linux-gnu
        /usr/local/lib
        /opt/rk3588-toolkit/lib
    REQUIRED
)
message(STATUS "Found librga: ${RGA_LIB}")

# RGA 头文件路径 (librga 2.0 im2d API)
set(ENGINE_INCLUDE_DIR ${CMAKE_SOURCE_DIR}/include)
set(ENGINE_INCLUDE_DIRS ${ENGINE_INCLUDE_DIR})
find_path(RGA_INCLUDE_DIR
    NAMES im2d.hpp
    PATHS
        /usr/include
        /usr/include/rga
        /usr/include/librga
        /usr/local/include
        /usr/local/include/rga
        /opt/rk3588-toolkit/include
        /opt/rk3588-toolkit/include/rga
)
if(RGA_INCLUDE_DIR)
    message(STATUS "Found RGA headers: ${RGA_INCLUDE_DIR}")
    list(APPEND ENGINE_INCLUDE_DIRS ${RGA_INCLUDE_DIR})
    set(HAS_RGA TRUE)
    add_compile_definitions(HAS_RGA)
else()
    message(WARNING "RGA headers (im2d.hpp) not found - rga_pipeline may not compile")
endif()

# yaml-cpp (YAML 配置解析)
find_package(yaml-cpp REQUIRED)
message(STATUS "Found yaml-cpp: ${YAML_CPP_INCLUDE_DIR}")

# ── 头文件路径 ──

# ── 源文件 ──
set(ENGINE_SOURCES
    src/engine.cpp
    src/model_loader.cpp
    src/preprocessor.cpp
    src/postprocessor.cpp
    src/rga_pipeline.cpp
)

# ── 共享库: libengine.so ──
add_library(engine SHARED ${ENGINE_SOURCES})

target_include_directories(engine
    PUBLIC
        ${ENGINE_INCLUDE_DIRS}
        ${YAML_CPP_INCLUDE_DIR}
)

target_link_libraries(engine
    PUBLIC
        ${RKNNRT_LIB}
        ${RGA_LIB}
        yaml-cpp
)

# 设置 soname
set_target_properties(engine PROPERTIES
    VERSION ${PROJECT_VERSION}
    SOVERSION 1
    OUTPUT_NAME engine
)

# 安装规则
install(TARGETS engine
    LIBRARY DESTINATION lib
    ARCHIVE DESTINATION lib
)

install(DIRECTORY ${ENGINE_INCLUDE_DIR}/
    DESTINATION include/rk3588/engine
    FILES_MATCHING PATTERN "*.h"
)

# ── 可执行文件: demo_inference ──
add_executable(demo_inference
    src/main.cpp
)

target_include_directories(demo_inference
    PRIVATE
        ${ENGINE_INCLUDE_DIR}
)

target_link_libraries(demo_inference
    PRIVATE
        engine
)

install(TARGETS demo_inference
    RUNTIME DESTINATION bin
)

# ── 编译信息摘要 ──
message(STATUS "")
message(STATUS "RK3588 推理引擎 构建配置")
message(STATUS "──────────────────────────────────")
message(STATUS "  版本:       ${PROJECT_VERSION}")
message(STATUS "  C++ 标准:   C++${CMAKE_CXX_STANDARD}")
message(STATUS "  构建类型:   ${CMAKE_BUILD_TYPE}")
message(STATUS "  安装前缀:   ${CMAKE_INSTALL_PREFIX}")
message(STATUS "  产物:")
message(STATUS "    libengine.so      共享库")
message(STATUS "    demo_inference    演示程序")
message(STATUS "──────────────────────────────────")
