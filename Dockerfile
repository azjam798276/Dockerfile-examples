ARG UBUNTU_VERSION=24.04
ARG CUDA_VERSION=12.8.1

# Target the CUDA build image
ARG BASE_CUDA_DEV_CONTAINER=nvidia/cuda:${CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION}
ARG BASE_CUDA_RUN_CONTAINER=nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu${UBUNTU_VERSION}

# Build-time ROCm base (CUDA devel + ROCm)
FROM ${BASE_CUDA_DEV_CONTAINER} AS build-rocm-base

# Set frontend to noninteractive
ENV DEBIAN_FRONTEND=noninteractive

# --- THIS IS THE CORRECTED APT-BASED ROCM INSTALL ---
#RUN apt-get update && apt-get install -y --no-install-recommends     build-essential wget curl gpg ca-certificates cmake git     libcurl4-openssl-dev libgomp1 libnuma1 kmod     libxcb-xinput0 libxcb-xinerama0 libxcb-cursor-dev     && curl -fsSL "https://repo.radeon.com/rocm/rocm%20GPG%20Key.gpg" | gpg --dearmor -o /usr/share/keyrings/rocm.gpg     && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/6.1.1 noble main" > /etc/apt/sources.list.d/rocm.list     && printf "Package: *\nPin: release o=repo.radeon.com\nPin-Priority: 1001" > /etc/apt/preferences.d/rocm-pin-1001     && apt-get update
RUN apt-get update && apt-get install -y --no-install-recommends     build-essential wget curl gpg ca-certificates cmake git     libcurl4-openssl-dev libgomp1 libnuma1 kmod     && curl -fsSL "https://repo.radeon.com/rocm/rocm.gpg.key" | gpg --dearmor -o /usr/share/keyrings/rocm.gpg     && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/6.3.3 noble main" > /etc/apt/sources.list.d/rocm.list     && printf "Package: *\nPin: release o=repo.radeon.com\nPin-Priority: 1001" > /etc/apt/preferences.d/rocm-pin-1001     && apt-get update
# Install the full ROCm SDK
RUN apt-get install -y --no-install-recommends rocm-hip-sdk rocblas-dev hipblas-dev rocm-smi-lib     && apt-get clean && rm -rf /var/lib/apt/lists/*

# Set ROCm environment variables
ENV ROCM_PATH=/opt/rocm
ENV HIP_PATH=/opt/rocm
ENV PATH=$ROCM_PATH/bin:$ROCM_PATH/llvm/bin:$PATH
ENV LD_LIBRARY_PATH=$ROCM_PATH/lib:$ROCM_PATH/lib64:$LD_LIBRARY_PATH

# Build stage with Vulkan SDK
FROM build-rocm-base AS build

# Install Vulkan SDK
ARG VULKAN_VERSION=1.4.321.1
RUN ARCH=$(uname -m) &&     wget -qO /tmp/vulkan-sdk.tar.xz "https://sdk.lunarg.com/sdk/download/${VULKAN_VERSION}/linux/vulkansdk-linux-${ARCH}-${VULKAN_VERSION}.tar.xz" &&     mkdir -p /opt/vulkan &&     tar -xf /tmp/vulkan-sdk.tar.xz -C /opt/vulkan --strip-components=1 &&     rm /tmp/vulkan-sdk.tar.xz

# Set Vulkan environment variables
ENV VULKAN_SDK=/opt/vulkan
ENV PATH=$VULKAN_SDK/bin:$PATH
ENV LD_LIBRARY_PATH=$VULKAN_SDK/lib:$LD_LIBRARY_PATH

# Set Architectures
ARG CUDA_DOCKER_ARCH=86
ARG AMDGPU_TARGETS=gfx1100
ARG LLAMA_COMMIT=master

# Clone llama.cpp
WORKDIR /
RUN git clone https://github.com/ggml-org/llama.cpp.git
WORKDIR /llama.cpp

# Build with CUDA, ROCm, and Vulkan backends
#RUN HIPCXX="$(hipconfig -l)/clang" HIP_PATH="$(hipconfig -R)"     cmake -B build     -DGGML_CUDA=ON -DGGML_HIP=ON     -DAMDGPU_TARGETS=${AMDGPU_TARGETS}     -DCMAKE_CUDA_ARCHITECTURES=${CUDA_DOCKER_ARCH}     -DCMAKE_SHARED_LINKER_FLAGS="-L/usr/local/cuda/lib64/stubs"     -DCMAKE_BUILD_TYPE=Release &&     cmake --build build --config Release -j$(nproc)
RUN CMAKE_ARGS="" && \
    if [ "${CUDA_DOCKER_ARCH}" != "default" ]; then \
        CMAKE_ARGS="${CMAKE_ARGS} -DCMAKE_CUDA_ARCHITECTURES=${CUDA_DOCKER_ARCH}"; \
    fi && \
    HIPCXX="$(hipconfig -l)/clang" HIP_PATH="$(hipconfig -R)" \
    cmake -B build \
    -DGGML_NATIVE=OFF \
    -DGGML_CUDA=ON \
    -DGGML_HIP=ON \
    -DLLAMA_MM_SUPPORT=OFF \
    -DGGML_BACKEND_DL=ON \
    -DGGML_CPU_ALL_VARIANTS=ON \
    -DLLAMA_BUILD_TESTS=OFF \
    -DAMDGPU_TARGETS=${AMDGPU_TARGETS} \
    -DCMAKE_BUILD_TYPE=Release \
    ${CMAKE_ARGS} \
    -DCMAKE_EXE_LINKER_FLAGS=-Wl,--allow-shlib-undefined . && \
    cmake --build build --config Release -j$(nproc)

# --- Runtime Image ---
FROM ${BASE_CUDA_RUN_CONTAINER} AS runtime

# Install runtime dependencies
RUN apt-get update &&     apt-get install -y libgomp1 curl libvulkan-dev libnuma1 kmod &&     apt-get clean && rm -rf /var/lib/apt/lists/*

# Copy pre-installed ROCm from build stage
COPY --from=build-rocm-base /opt/rocm /opt/rocm

# Set ROCm environment variables
ENV ROCM_PATH=/opt/rocm
ENV HIP_PATH=/opt/rocm
ENV PATH=$ROCM_PATH/bin:$PATH
ENV LD_LIBRARY_PATH=$ROCM_PATH/lib:$ROCM_PATH/lib64:$LD_LIBRARY_PATH
ENV NVIDIA_DRIVER_CAPABILITIES=all
ENV NVIDIA_VISIBLE_DEVICES=all

# Copy compiled llama.cpp binaries from the build stage
COPY --from=build /llama.cpp/build/bin/* /usr/local/bin/

WORKDIR /app
ENTRYPOINT ["/bin/bash"]
