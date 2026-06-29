cmake_minimum_required(VERSION 3.16)
project(rk3588_opcua_server LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 查找依赖
find_package(Open62541 REQUIRED)
find_package(yaml-cpp REQUIRED)

# 源文件
set(OPCUA_SOURCES
    src/opcua_server.cpp
    src/node_manager.cpp
    src/main.cpp
)

# 可执行文件
add_executable(opcua_server ${OPCUA_SOURCES})

target_include_directories(opcua_server PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${Open62541_INCLUDE_DIRS}
    ${YAML_CPP_INCLUDE_DIRS}
)

target_link_libraries(opcua_server PRIVATE
    open62541
    yaml-cpp
    pthread
)

# 安装
install(TARGETS opcua_server
    RUNTIME DESTINATION bin
)

install(DIRECTORY config/
    DESTINATION etc/rk3588/opcua
    FILES_MATCHING PATTERN "*.yaml"
)
