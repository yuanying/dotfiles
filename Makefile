IMAGE := registry.fraction.jp/yuanying/devbox

.PHONY: image
image:
		docker build \
			--build-arg BASE_IMAGE=ubuntu:24.04 \
			--target user_base -t $(IMAGE)-amd64:user_base \
			--target main -t $(IMAGE)-amd64 .

.PHONY: rocm
rocm:
		docker build \
			--build-arg BASE_IMAGE=rocm/dev-ubuntu-24.04:7.2.2-complete \
			--target user_base -t $(IMAGE)-rocm:user_base \
			--target main -t $(IMAGE)-rocm .

.PHONY: cuda
cuda:
		docker build \
			--build-arg BASE_IMAGE=nvidia/cuda:13.1.0-devel-ubuntu24.04 \
			--network host \
			--target user_base -t $(IMAGE)-cuda:user_base \
			--target main -t $(IMAGE)-cuda .
