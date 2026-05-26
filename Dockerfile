# Build torch+xpu on Intel's oneAPI image, then ship it on a slim runtime stage.
#
# torch+xpu's pip wheels bundle the entire oneAPI runtime they need (SYCL, MKL,
# OpenMP, Unified Runtime + the Level Zero/OpenCL adapters) under /usr/local/lib,
# so the oneAPI install baked into the build image (/opt/intel, ~3.2GB) is pure
# duplication. The final stage is plain ubuntu plus only the Intel GPU userspace
# driver (Level Zero + compute runtime), which is the one piece torch does NOT
# bundle. Net: ~13GB -> ~8.5GB.
FROM intel/oneapi-runtime:2025.3.1-0-devel-ubuntu24.04 AS builder
ARG PIP_OPTS=""
ENV PIP_OPTS=$PIP_OPTS
RUN apt-get -y update && apt-get install -yq --no-install-recommends python3 python3-pip python-dev-is-python3 && pip install --no-cache-dir $PIP_OPTS --break-system-packages torch torchvision torchaudio --index-url http://download.pytorch.org/whl/xpu --trusted-host download.pytorch.org

FROM ubuntu:24.04
# ca-certificates first (Ubuntu http repo) so apt can fetch the Intel GPU repo
# over https; reuse the build image's signing key for that repo.
COPY --from=builder /usr/share/keyrings/intel-graphics-archive-keyring.gpg /usr/share/keyrings/
RUN apt-get -y update && apt-get install -yq --no-install-recommends \
        ca-certificates python3 python3-pip python-dev-is-python3 \
    && echo "deb [signed-by=/usr/share/keyrings/intel-graphics-archive-keyring.gpg arch=amd64] https://repositories.intel.com/gpu/ubuntu noble unified" > /etc/apt/sources.list.d/intel-graphics.list \
    && apt-get -y update && apt-get install -yq --no-install-recommends \
        intel-opencl-icd libze1 libze-intel-gpu1 libigc2 libigdgmm12 \
    && rm -rf /var/lib/apt/lists/*
# The torch+xpu install, with its bundled oneAPI runtime libraries.
COPY --from=builder /usr/local /usr/local
RUN ldconfig
