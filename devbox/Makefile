IMAGE := registry.fraction.jp/yuanying/devbox

# Held at 24.04 on purpose (updates are disabled in renovate.json)
# renovate: datasource=docker depName=ubuntu versioning=ubuntu
UBUNTU_IMAGE := ubuntu:24.04
# renovate: datasource=docker depName=rocm/dev-ubuntu-24.04 versioning=regex:^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)-complete$
ROCM_IMAGE := rocm/dev-ubuntu-24.04:7.2.4-complete
# renovate: datasource=docker depName=nvidia/cuda versioning=regex:^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)-devel-ubuntu24\.04$
CUDA_IMAGE := nvidia/cuda:13.3.1-devel-ubuntu24.04

.PHONY: image
image:
		docker build \
			--build-arg BASE_IMAGE=$(UBUNTU_IMAGE) \
			--target user_base -t $(IMAGE)-amd64:user_base \
			--target main -t $(IMAGE)-amd64 .

.PHONY: rocm
rocm:
		docker build \
			--build-arg BASE_IMAGE=$(ROCM_IMAGE) \
			--target user_base -t $(IMAGE)-rocm:user_base \
			--target main -t $(IMAGE)-rocm .

.PHONY: cuda
cuda:
		docker build \
			--build-arg BASE_IMAGE=$(CUDA_IMAGE) \
			--network host \
			--target user_base -t $(IMAGE)-cuda:user_base \
			--target main -t $(IMAGE)-cuda .
