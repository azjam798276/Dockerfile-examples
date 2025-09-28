# We will use Ubuntu 24.04 and CUDA 12.8.1 as a base, as specified
ARG UBUNTU_VERSION=24.04
ARG CUDA_VERSION=12.8.1

# Target CUDA base images
ARG BASE_CUDA_DEV_CONTAINER=nvidia/cuda:${CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION}
ARG BASE_CUDA_RUN_CONTAINER=nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu${UBUNTU_VERSION}

# Build-time ROCm base (CUDA devel + ROCm)
FROM ${BASE_CUDA_DEV_CONTAINER} AS build-rocm-base

# Install build tools and dependencies
RUN apt-get update && \
    apt-get install -y build-essential cmake python3 python3-pip git \
    libcurl4-openssl-dev libgomp1 wget xz-utils zstd \
    libxcb-xinput0 libxcb-xinerama0 libxcb-cursor-dev \
    libnuma1 kmod rsync dialog \
    gfortran git-lfs ninja-build cmake g++ pkg-config xxd patchelf automake libtool python3-venv python3-dev libegl1-mesa-dev

# Install ROCm from official repository
RUN --mount=type=cache,target=/cache/amdgpu-build \
    if [ ! -f /cache/amdgpu-build/amdgpu-install_7.0.1.70001-1_all.deb ]; then \
        wget https://repo.radeon.com/amdgpu-install/7.0.1/ubuntu/noble/amdgpu-install_7.0.1.70001-1_all.deb -O /cache/amdgpu-build/amdgpu-install_7.0.1.70001-1_all.deb; \
    fi && \
    apt-get update && \
    apt-get install -y /cache/amdgpu-build/amdgpu-install_7.0.1.70001-1_all.deb && \
    apt update && \
    apt install -y rocm

# Set ROCm environment variables
ENV ROCM_PATH=/opt/rocm
ENV HIP_PATH=/opt/rocm
ENV PATH=$ROCM_PATH/bin:$ROCM_PATH/llvm/bin:$PATH
ENV LD_LIBRARY_PATH=$ROCM_PATH/lib:$ROCM_PATH/lib64:$LD_LIBRARY_PATH

# Build stage with Vulkan SDK
FROM build-rocm-base AS build

# GPU architecture configuration
ARG CUDA_DOCKER_ARCH=86
ARG AMDGPU_TARGETS=gfx1100
ARG LLAMA_COMMIT=1d660d2fae42ea2e1d3569638e722bf7a37b6b19

# Install Vulkan SDK
ARG VULKAN_VERSION=1.4.321.1
RUN --mount=type=cache,target=/cache/vulkan \
    ARCH=$(uname -m) && \
    if [ ! -f /cache/vulkan/vulkan-sdk-linux-${ARCH}-${VULKAN_VERSION}.tar.xz ]; then \
        wget -qO /cache/vulkan/vulkan-sdk-linux-${ARCH}-${VULKAN_VERSION}.tar.xz https://sdk.lunarg.com/sdk/download/${VULKAN_VERSION}/linux/vulkan-sdk-linux-${ARCH}-${VULKAN_VERSION}.tar.xz; \
    fi && \
    mkdir -p /opt/vulkan && \
    tar -xf /cache/vulkan/vulkan-sdk-linux-${ARCH}-${VULKAN_VERSION}.tar.xz -C /tmp --strip-components=1 && \
    mv /tmp/${ARCH}/* /opt/vulkan/ && \
    rm -rf /tmp/*

# Set Vulkan environment variables
ENV VULKAN_SDK=/opt/vulkan
ENV PATH=$VULKAN_SDK/bin:$PATH
ENV LD_LIBRARY_PATH=$VULKAN_SDK/lib:$LD_LIBRARY_PATH

# Clone llama.cpp and set working directory
WORKDIR /app
RUN git clone --branch master --single-branch --recurse-submodules https://github.com/ggerganov/llama.cpp.git --config advice.detachedHead=false
WORKDIR /app/llama.cpp 
# The patch step is commented out to avoid the "corrupt patch" error.
# COPY rocwmma.patch .
# RUN git apply rocwmma.patch

# Build with CUDA, ROCm, and Vulkan backends
RUN CMAKE_ARGS="" && \
    if [ "${CUDA_DOCKER_ARCH}" != "default" ]; then \
        CMAKE_ARGS="${CMAKE_ARGS} -DCMAKE_CUDA_ARCHITECTURES=${CUDA_DOCKER_ARCH}"; \
    fi && \
    HIPCXX="$(hipconfig -l)/clang" HIP_PATH="$(hipconfig -R)" \
    cmake -B build \
    -DGGML_NATIVE=OFF \
    -DGGML_CUDA=ON \
    -DGGML_HIP=ON \
    -DGGML_VULKAN=ON \
    -DGGML_HIP_ROCWMMA_FATTN=ON \
    -DGGML_SCHED_MAX_COPIES=1 \
    -DGGML_BACKEND_DL=ON \
    -DLLAMA_BUILD_TESTS=OFF \
    -DAMDGPU_TARGETS=${AMDGPU_TARGETS} \
    -DCMAKE_BUILD_TYPE=Release \
    ${CMAKE_ARGS} \
    -DCMAKE_EXE_LINKER_FLAGS=-Wl,--allow-shlib-undefined . && \
    cmake --build build --config Release -j$(nproc)

RUN mkdir -p /app/lib && \
    find build -name "*.so" -exec cp {} /app/lib \;

RUN mkdir -p /app/full && \
    cp build/bin/* /app/full && \
    cp *.py /app/full && \
    cp -r gguf-py /app/full && \
    cp -r requirements /app/full && \
    cp requirements.txt /app/full && \
    cp .devops/tools.sh /app/full/tools.sh

# Runtime ROCm base (CUDA runtime + ROCm)
FROM ${BASE_CUDA_RUN_CONTAINER} AS runtime-rocm-base

# Install runtime dependencies
RUN apt-get update && \
    apt-get install -y libgomp1 curl wget libvulkan-dev libnuma1 kmod rsync dialog zstd && \
    apt autoremove -y && \
    apt clean -y && \
    rm -rf /tmp/* /var/tmp/* && \
    find /var/cache/apt/archives /var/lib/apt/lists -not -name lock -type f -delete && \
    find /var/cache -type f -delete

# Install ROCm from official repository
RUN --mount=type=cache,target=/cache/amdgpu-runtime \
    if [ ! -f /cache/amdgpu-runtime/amdgpu-install_7.0.1.70001-1_all.deb ]; then \
        wget https://repo.radeon.com/amdgpu-install/7.0.1/ubuntu/noble/amdgpu-install_7.0.1.70001-1_all.deb -O /cache/amdgpu-runtime/amdgpu-install_7.0.1.70001-1_all.deb; \
    fi && \
    apt-get update && \
    apt-get install -y /cache/amdgpu-runtime/amdgpu-install_7.0.1.70001-1_all.deb && \
    apt update && \
    apt install -y rocm

# Set ROCm environment variables
ENV ROCM_PATH=/opt/rocm
ENV HIP_PATH=/opt/rocm
ENV PATH=$ROCM_PATH/bin:$PATH
ENV LD_LIBRARY_PATH=$ROCM_PATH/lib:$ROCM_PATH/lib64:$LD_LIBRARY_PATH

# Base runtime image
FROM runtime-rocm-base AS base

COPY --from=build /app/lib/ /app

# Full runtime image
FROM base AS full
ENV NVIDIA_DRIVER_CAPABILITIES=all
ENV NVIDIA_VISIBLE_DEVICES=all


COPY --from=build /app/full /app

WORKDIR /app

RUN apt-get update \
    && apt-get install -y \
    git \
    python3 \
    python3-pip \
    python3-wheel \
    pciutils \
    vulkan-tools \
    mesa-utils \
    rocm-smi \
    && pip install --break-system-packages -r requirements.txt \
    && apt autoremove -y \
    && apt clean -y \
    && rm -rf /tmp/* /var/tmp/* \
    && find /var/cache/apt/archives /var/lib/apt/lists -not -name lock -type f -delete \
    && find /var/cache -type f -delete


# Server and light omitted
