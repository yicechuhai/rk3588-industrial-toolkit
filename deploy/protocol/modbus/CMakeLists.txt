cmake_minimum_required(VERSION 3.16)
project(rk3588_modbus_server VERSION 1.0.0 LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(PkgConfig REQUIRED)
pkg_check_modules(LIBMODBUS REQUIRED libmodbus)
pkg_check_modules(YAMLCPP REQUIRED yaml-cpp)

add_library(modbus_server STATIC
    src/modbus_server.cpp
    src/register_map.cpp
)

target_include_directories(modbus_server PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${LIBMODBUS_INCLUDE_DIRS}
    ${YAMLCPP_INCLUDE_DIRS}
)

target_link_libraries(modbus_server PUBLIC
    ${LIBMODBUS_LIBRARIES}
    ${YAMLCPP_LIBRARIES}
)

add_executable(modbus_server_demo src/main.cpp)
target_include_directories(modbus_server_demo PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)
target_link_libraries(modbus_server_demo PRIVATE modbus_server)

install(TARGETS modbus_server ARCHIVE DESTINATION lib)
install(TARGETS modbus_server_demo RUNTIME DESTINATION bin)
