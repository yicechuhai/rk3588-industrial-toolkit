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

# yaml-cpp (YAML 配置解析)
find_package(yaml-cpp REQUIRED)
message(STATUS "Found yaml-cpp: ${YAML_CPP_INCLUDE_DIR}")

# ── 头文件路径 ──
set(ENGINE_INCLUDE_DIR ${CMAKE_SOURCE_DIR}/include)

# ── 源文件 ──
set(ENGINE_SOURCES
    src/engine.cpp
    src/model_loader.cpp
    src/preprocessor.cpp
    src/postprocessor.cpp
)

# ── 共享库: libengine.so ──
add_library(engine SHARED ${ENGINE_SOURCES})

target_include_directories(engine
    PUBLIC
        ${ENGINE_INCLUDE_DIR}
        ${YAML_CPP_INCLUDE_DIR}
)

target_link_libraries(engine
    PUBLIC
        ${RKNNRT_LIB}
        ${RGA_LIB}
        yaml-cpp::yaml-cpp
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

# ============================================================================
# Python 绑定模块 (pybind11)
# ============================================================================
# 构建方式:
#   cd deploy/engine && mkdir build && cd build
#   cmake .. -DPYTHON_EXECUTABLE=$(which python3) -DBUILD_PYTHON=ON
#   make rknn_engine_python -j4
#
# 或直接:
#   cd deploy/engine/python && pip install .
# ============================================================================

option(BUILD_PYTHON "Build Python bindings via pybind11" ON)

if(BUILD_PYTHON)
    # ── 查找 pybind11 ──
    find_package(pybind11 CONFIG QUIET)
    if(NOT pybind11_FOUND)
        # 通过 pip 安装到用户 site-packages
        message(STATUS "pybind11 not found via CMake, trying via pip...")
        execute_process(
            COMMAND ${PYTHON_EXECUTABLE} -m pybind11 --cmakedir
            OUTPUT_VARIABLE PYBIND11_CMAKE_DIR
            OUTPUT_STRIP_TRAILING_WHITESPACE
            ERROR_QUIET
        )
        if(PYBIND11_CMAKE_DIR)
            list(APPEND CMAKE_PREFIX_PATH "${PYBIND11_CMAKE_DIR}")
            find_package(pybind11 CONFIG REQUIRED)
        else()
            message(FATAL_ERROR
                "pybind11 not found. Install with: pip install pybind11")
        endif()
    endif()
    message(STATUS "Found pybind11: ${pybind11_DIR}")

    # ── 查找 Python (NumPy headers 需要) ──
    if(NOT DEFINED PYTHON_EXECUTABLE)
        find_package(Python COMPONENTS Interpreter Development REQUIRED)
    else()
        find_package(Python COMPONENTS Interpreter Development
            REQUIRED
            HINTS ${PYTHON_EXECUTABLE})
    endif()

    # 获取 NumPy include 路径
    execute_process(
        COMMAND ${Python_EXECUTABLE} -c
            "import numpy; print(numpy.get_include())"
        OUTPUT_VARIABLE NUMPY_INCLUDE_DIR
        OUTPUT_STRIP_TRAILING_WHITESPACE
        REQUIRED
    )

    # ── pybind11 模块 ──
    set(PYBIND11_SOURCES
        python/bindings.cpp
    )

    pybind11_add_module(rknn_engine_python SHARED ${PYBIND11_SOURCES})

    target_include_directories(rknn_engine_python
        PRIVATE
            ${ENGINE_INCLUDE_DIR}
            ${YAML_CPP_INCLUDE_DIR}
            ${NUMPY_INCLUDE_DIR}
    )

    target_link_libraries(rknn_engine_python
        PRIVATE
            engine                 # reuse the existing libengine.so target
            pybind11::headers
            ${RKNNRT_LIB}
            ${RGA_LIB}
            yaml-cpp::yaml-cpp
    )

    set_target_properties(rknn_engine_python PROPERTIES
        OUTPUT_NAME rknn_engine
        CXX_STANDARD 17
        CXX_STANDARD_REQUIRED ON
        POSITION_INDEPENDENT_CODE ON
    )

    # 安装到 Python site-packages
    install(TARGETS rknn_engine_python
        LIBRARY DESTINATION ${Python_SITELIB}
    )

    # 安装 __init__.py
    install(FILES python/__init__.py
        DESTINATION ${Python_SITELIB}/rknn_engine
    )

    message(STATUS "  rknn_engine_python  Python 绑定模块")

endif()

# ── 编译信息摘要 ──
message(STATUS "")
message(STATUS "RK3588 推理引擎 构建配置")
message(STATUS "──────────────────────────────────")
message(STATUS "  版本:       ${PROJECT_VERSION}")
message(STATUS "  C++ 标准:   C++${CMAKE_CXX_STANDARD}")
message(STATUS "  构建类型:   ${CMAKE_BUILD_TYPE}")
message(STATUS "  安装前缀:   ${CMAKE_INSTALL_PREFIX}")
message(STATUS "  产物:")
message(STATUS "    libengine.so            共享库")
message(STATUS "    demo_inference          演示程序")
if(BUILD_PYTHON AND pybind11_FOUND)
    message(STATUS "    rknn_engine_python      Python 绑定模块")
endif()
message(STATUS "──────────────────────────────────")
