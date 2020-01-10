#!/bin/bash
set -eou pipefail
TAG_FOR_THIS_BUILD="local_$(python3 -c 'import time; print(int(time.time() * 1e9))')"
IMAGE_NAME="python-android-support-3.7:${TAG_FOR_THIS_BUILD}"
docker build -t "$IMAGE_NAME" -f 3.7.Dockerfile .
rm -rf ./output/3.7
mkdir -p output/3.7/
docker run -v $PWD/output/3.7/:/mnt/output --rm --entrypoint cp "$IMAGE_NAME" -a applibs/ /mnt/output
docker run -v $PWD/output/3.7/:/mnt/output --rm --entrypoint cp "$IMAGE_NAME" -a assets/ /mnt/output
