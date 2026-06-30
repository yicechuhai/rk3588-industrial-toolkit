# ============================================================================
# RK3588 统一推理流水线 — CMake 构建配置
# ============================================================================
cmake_minimum_required(VERSION 3.16)
project(rk3588_pipeline VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(CMAKE_BUILD_TYPE STREQUAL "Release")
    add_compile_options(-O3 -DNDEBUG -march=armv8.2-a+dotprod+fp16)
else()
    add_compile_options(-O2 -g -DDEBUG)
endif()
add_compile_options(-Wall -Wextra -Wno-unused-parameter)

# OpenCV
find_package(OpenCV REQUIRED COMPONENTS core videoio imgproc highgui)

# Engine
set(ENGINE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../engine")
set(ENGINE_INCLUDE_DIR "${ENGINE_DIR}/include")
find_library(ENGINE_LIB engine
    PATHS "${CMAKE_BINARY_DIR}/../engine" "${ENGINE_DIR}/build" /usr/local/lib /opt/rk3588-toolkit/lib REQUIRED)

# Modbus server
set(MODBUS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../protocol/modbus")
set(MODBUS_INCLUDE_DIR "${MODBUS_DIR}/include")
find_library(MODBUS_LIB modbus_server
    PATHS "${CMAKE_BINARY_DIR}/../protocol/modbus" "${MODBUS_DIR}/build" /usr/local/lib /opt/rk3588-toolkit/lib REQUIRED)

# OPC UA server
set(OPCUA_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../protocol/opcua")
set(OPCUA_INCLUDE_DIR "${OPCUA_DIR}/include")
find_library(OPCUA_LIB opcua_server
    PATHS "${CMAKE_BINARY_DIR}/../protocol/opcua" "${OPCUA_DIR}/build" /usr/local/lib /opt/rk3588-toolkit/lib REQUIRED)

find_package(PkgConfig REQUIRED)
pkg_check_modules(LIBMODBUS REQUIRED libmodbus)
pkg_check_modules(OPEN62541 REQUIRED open62541)
find_package(yaml-cpp REQUIRED)

add_executable(pipeline_runner pipeline_runner.cpp)
target_include_directories(pipeline_runner PRIVATE
    ${ENGINE_INCLUDE_DIR} ${MODBUS_INCLUDE_DIR} ${OPCUA_INCLUDE_DIR}
    ${OpenCV_INCLUDE_DIRS} ${LIBMODBUS_INCLUDE_DIRS} ${OPEN62541_INCLUDE_DIRS} ${YAML_CPP_INCLUDE_DIR})
target_link_libraries(pipeline_runner PRIVATE
    ${ENGINE_LIB} ${MODBUS_LIB} ${OPCUA_LIB}
    ${OpenCV_LIBS} ${LIBMODBUS_LIBRARIES} ${OPEN62541_LIBRARIES} yaml-cpp pthread)

install(TARGETS pipeline_runner RUNTIME DESTINATION bin)
message(STATUS "Pipeline runner configured: pipeline_runner")
