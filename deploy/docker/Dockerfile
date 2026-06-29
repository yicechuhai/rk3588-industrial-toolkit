#===============================================================================
# RK3588 Industrial Toolkit — Dockerfile (ARM64 目标平台构建)
#
# 构建方式:
#   docker build -t rk3588-toolkit:latest \
#     --build-arg RKNN_RUNTIME_DEB=./rknn-toolkit-lite2_2.1.0-1_arm64.deb \
#     -f deploy/docker/Dockerfile .
#===============================================================================

FROM --platform=linux/arm64 ubuntu:22.04

LABEL org.opencontainers.image.title="RK3588 Industrial Toolkit"
LABEL org.opencontainers.image.description="AI推理引擎 + Modbus/OPC UA 工业协议栈"
LABEL org.opencontainers.image.authors="yicechuhai"
LABEL org.opencontainers.image.version="1.0.0"

#===============================================================================
# 构建参数
#===============================================================================
ARG RKNN_RUNTIME_DEB
ARG DEBIAN_FRONTEND=noninteractive

#===============================================================================
# 安装系统依赖
#===============================================================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    pkg-config \
    git \
    ca-certificates \
    librga2 \
    librga-dev \
    libdrm2 \
    libdrm-dev \
    libmodbus5 \
    libmodbus-dev \
    libopen62541-1.1 \
    libopen62541-dev \
    libyaml-cpp0.7 \
    libyaml-cpp-dev \
    python3 \
    python3-pip \
    python3-dev \
    python3-numpy \
    curl \
    wget \
    udev \
    && rm -rf /var/lib/apt/lists/*

#===============================================================================
# 安装 RKNN Runtime (从外部 deb 包)
#===============================================================================
COPY ${RKNN_RUNTIME_DEB} /tmp/rknn-runtime.deb
RUN dpkg -i /tmp/rknn-runtime.deb || apt-get install -f -y --no-install-recommends \
    && rm -f /tmp/rknn-runtime.deb \
    && ldconfig

#===============================================================================
# 复制源码
#===============================================================================
WORKDIR /build

COPY CMakeLists.txt .
COPY cmake/ cmake/
COPY deploy/engine/ deploy/engine/
COPY deploy/protocol/ deploy/protocol/
COPY configs/ configs/

#===============================================================================
# 构建零拷贝推理引擎
#===============================================================================
RUN cmake -B build/engine \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_ENGINE=ON \
    -DBUILD_PYTHON_BINDINGS=ON \
    deploy/engine/ \
    && cmake --build build/engine --target engine -j$(nproc) \
    && cmake --build build/engine --target engine_py -j$(nproc)

#===============================================================================
# 构建 Modbus 协议适配器
#===============================================================================
RUN cmake -B build/modbus \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_MODBUS=ON \
    deploy/protocol/modbus/ \
    && cmake --build build/modbus -j$(nproc)

#===============================================================================
# 构建 OPC UA 协议适配器
#===============================================================================
RUN cmake -B build/opcua \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_OPCUA=ON \
    deploy/protocol/opcua/ \
    && cmake --build build/opcua -j$(nproc)

#===============================================================================
# 安装到 /opt/rk3588-toolkit/
#===============================================================================
ENV INSTALL_DIR=/opt/rk3588-toolkit

RUN mkdir -p ${INSTALL_DIR}/lib \
    && mkdir -p ${INSTALL_DIR}/bin \
    && mkdir -p ${INSTALL_DIR}/configs \
    && mkdir -p ${INSTALL_DIR}/models \
    && mkdir -p ${INSTALL_DIR}/logs \
    && mkdir -p ${INSTALL_DIR}/python

RUN cp build/engine/libengine.so ${INSTALL_DIR}/lib/ \
    && cp build/engine/engine_py*.so ${INSTALL_DIR}/python/ 2>/dev/null || true

RUN cp build/modbus/modbus_server ${INSTALL_DIR}/bin/ \
    && cp build/opcua/opcua_server ${INSTALL_DIR}/bin/

RUN cp -r configs/yaml_templates/* ${INSTALL_DIR}/configs/ 2>/dev/null || true

COPY deploy/docker/entrypoint.sh ${INSTALL_DIR}/entrypoint.sh
RUN chmod +x ${INSTALL_DIR}/entrypoint.sh

RUN rm -rf /build

#===============================================================================
# 运行时配置
#===============================================================================
ENV LD_LIBRARY_PATH=${INSTALL_DIR}/lib:${LD_LIBRARY_PATH}
ENV PYTHONPATH=${INSTALL_DIR}/python:${PYTHONPATH}
ENV PATH=${INSTALL_DIR}/bin:${PATH}

WORKDIR ${INSTALL_DIR}

EXPOSE 502 4840 50051

STOPSIGNAL SIGTERM

ENTRYPOINT ["/opt/rk3588-toolkit/entrypoint.sh"]
