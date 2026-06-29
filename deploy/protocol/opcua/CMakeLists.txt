cmake_minimum_required(VERSION 3.16)
project(rk3588_opcua_server LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_library(OPEN62541_LIB open62541 PATHS /usr/local/lib REQUIRED)
find_path(OPEN62541_INCLUDE_DIR open62541.h PATHS /usr/local/include REQUIRED)
find_package(yaml-cpp REQUIRED)

set(OPCUA_SOURCES
    src/opcua_server.cpp
    src/node_manager.cpp
    src/main.cpp
)

add_executable(opcua_server ${OPCUA_SOURCES})

target_include_directories(opcua_server PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${OPEN62541_INCLUDE_DIR}
    ${YAML_CPP_INCLUDE_DIRS}
)

target_link_libraries(opcua_server PRIVATE
    ${OPEN62541_LIB}
    ${YAML_CPP_LIBRARIES}
    pthread
)

install(TARGETS opcua_server RUNTIME DESTINATION bin)
