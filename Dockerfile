# syntax=docker/dockerfile:1
# Build torch+xpu on Intel's oneAPI image, then ship it on a slim runtime stage.
#
# torch+xpu's pip wheels bundle the entire oneAPI runtime they need (SYCL, MKL,
# OpenMP, Unified Runtime + the Level Zero/OpenCL adapters) under /usr/local/lib,
# so the oneAPI install baked into the build image (/opt/intel, ~3.2GB) is pure
# duplication. The final stage is plain ubuntu plus the pieces torch does NOT
# bundle: the Intel GPU userspace driver (Level Zero + compute runtime), and the
# toolchain torch.compile needs to JIT XPU kernels. torch.compile on XPU builds a
# Triton spirv_utils helper at runtime that #includes <level_zero/ze_api.h> and
# <sycl/sycl.hpp> and links libze_loader/libsycl, then shells out to `ocloc` to
# turn the kernel's SPIR-V into a GPU binary. So it needs g++, the Level Zero
# headers (libze-dev -- libze1 ships only the .so), Python.h (python3-dev, via
# python-dev-is-python3) and the ocloc compiler (intel-ocloc); the SYCL headers
# come from the intel-sycl-rt wheel. Without g++: "InvalidCxxCompiler"; without
# libze-dev: "level_zero/ze_api.h: No such file"; without intel-ocloc:
# "FileNotFoundError: 'ocloc'". Net: ~13GB -> ~8.5GB. (The -devel build image
# shipped g++; plain ubuntu:24.04 does not.)
FROM intel/oneapi-runtime:2025.3.1-0-devel-ubuntu24.04 AS builder
ARG PIP_OPTS=""
ENV PIP_OPTS=$PIP_OPTS
# Drop the Intel GPU repo the base image preconfigures: the builder only needs
# base ubuntu (python3/pip) and pip-installs torch, and that repo intermittently
# 403s from cloud/CI runner IPs -- which would otherwise fail apt-get update here.
RUN rm -f /etc/apt/sources.list.d/intel-graphics.list \
    && apt-get -y update && apt-get install -yq --no-install-recommends python3 python3-pip python-dev-is-python3 \
    && pip install --no-cache-dir $PIP_OPTS --break-system-packages torch torchvision torchaudio --index-url http://download.pytorch.org/whl/xpu --trusted-host download.pytorch.org

FROM ubuntu:26.04
# ca-certificates first (Ubuntu http repo) so apt can fetch the Intel GPU repo
# over https; reuse the build image's signing key for that repo.
COPY --from=builder /usr/share/keyrings/intel-graphics-archive-keyring.gpg /usr/share/keyrings/
RUN apt-get -y update && apt-get install -yq --no-install-recommends \
        ca-certificates python3 python3-pip python-dev-is-python3 g++ \
    && echo "deb [signed-by=/usr/share/keyrings/intel-graphics-archive-keyring.gpg arch=amd64] https://repositories.intel.com/gpu/ubuntu noble unified" > /etc/apt/sources.list.d/intel-graphics.list \
    # The Intel GPU repo intermittently 403s from cloud/CI runner IPs, so retry
    # the update that refreshes it (apt treats a 403 as fatal, hence the loop).
    && for i in 1 2 3 4 5 6; do apt-get -y -o Acquire::Retries=3 update && break || { echo "intel gpu repo apt-get update failed (rate-limit/403), attempt $i/6"; sleep 20; }; done \
    && apt-get install -yq --no-install-recommends \
        intel-opencl-icd intel-ocloc libze1 libze-dev libze-intel-gpu1 libigc2 libigdgmm12 \
    && rm -rf /var/lib/apt/lists/*
# The torch+xpu install, with its bundled oneAPI runtime libraries (~8GB). Split
# across several COPY layers: a single ~2.9GB layer trips Docker Hub's blob-size
# limit on push ("400 Bad request" on the blob PUT). triton (~2.6GB) and the rest
# of the python packages go in their own layers; the loose oneAPI runtime libs
# (mkl/sycl/ccl/...) and everything else land in the last. The --exclude flags
# keep the layers disjoint so the tree is copied exactly once.
COPY --from=builder /usr/local/lib/python3.12/dist-packages/triton /usr/local/lib/python3.12/dist-packages/triton
COPY --from=builder --exclude=dist-packages/triton /usr/local/lib/python3.12 /usr/local/lib/python3.12
COPY --from=builder --exclude=lib/python3.12 /usr/local /usr/local
RUN ldconfig
