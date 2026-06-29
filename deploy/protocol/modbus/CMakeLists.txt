# =============================================================================
# Modbus TCP Server — CMake 构建配置
# 依赖: libmodbus, yaml-cpp
# =============================================================================

cmake_minimum_required(VERSION 3.16)
project(rk3588_modbus_server VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ── 查找依赖 ────────────────────────────────────────────
find_package(PkgConfig REQUIRED)

pkg_check_modules(LIBMODBUS REQUIRED libmodbus)
pkg_check_modules(YAMLCPP REQUIRED yaml-cpp)

# ── 库目标 ──────────────────────────────────────────────
add_library(modbus_server STATIC
    src/modbus_server.cpp
    src/register_map.cpp
)

target_include_directories(modbus_server PUBLIC
    /include
    
    
)

target_link_libraries(modbus_server PUBLIC
    
    
)

target_compile_options(modbus_server PRIVATE
    -Wall -Wextra -Wpedantic
)

# ── 可执行文件 (独立运行示例) ───────────────────────────
add_executable(modbus_server_demo
    src/main.cpp
)

target_link_libraries(modbus_server_demo PRIVATE
    modbus_server
)

# ── 安装 ────────────────────────────────────────────────
install(TARGETS modbus_server
    ARCHIVE DESTINATION lib
)

install(TARGETS modbus_server_demo
    RUNTIME DESTINATION bin
)

install(DIRECTORY include/
    DESTINATION include/rk3588/protocol/modbus
)

install(FILES config/modbus_example.yaml
    DESTINATION share/rk3588/modbus
)
