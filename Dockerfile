FROM intel/oneapi-runtime:2025.3.1-0-devel-ubuntu24.04 AS builder
ARG PIP_OPTS=""
ENV PIP_OPTS=$PIP_OPTS
RUN apt-get -y update && apt-get install -yq --no-install-recommends python3 python3-pip python-dev-is-python3 && pip install --no-cache-dir $PIP_OPTS --break-system-packages torch torchvision torchaudio --index-url http://download.pytorch.org/whl/xpu --trusted-host download.pytorch.org
