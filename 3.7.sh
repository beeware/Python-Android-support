#!/bin/bash
set -eou pipefail
chmod -R u+rw output/3.7 || sudo chown -R "$USER" output/3.7
rm -rf ./output/3.7
mkdir -p output/3.7
for shortname in x86_64; do
    TAG_FOR_THIS_BUILD="local_$(python3 -c 'import time; print(int(time.time() * 1e9))')"
    IMAGE_NAME="python-android-support-3.7:${TAG_FOR_THIS_BUILD}"
    docker build --build-arg TARGET_ABI_SHORTNAME="$shortname" -t "$IMAGE_NAME" -f 3.7.Dockerfile .
    # Using rsync -L so that libpython3.7.so.1.0.0 is copied into a file, not as a symlink.
    docker run -v $PWD/output/3.7/:/mnt/ --rm --entrypoint rsync "$IMAGE_NAME" -aL --delete /opt/python-build/approot/. /mnt/.
    docker run -v $PWD/output/3.7/:/mnt/ --rm --entrypoint rsync "$IMAGE_NAME" -aL /opt/python-build/built/python/include/python3.7m/pyconfig.h /mnt/
done
