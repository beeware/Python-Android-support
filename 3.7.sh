#!/bin/bash
set -eou pipefail
chmod -R u+rw output/3.7 || sudo chown -R "$USER" output/3.7
rm -rf ./output/3.7
mkdir -p output/3.7
for TARGET_ABI_SHORTNAME in x86 armeabi-v7a arm64-v8a x86_84; do
    # Using ANDROID_API_LEVEL=21 allows us to have a localeconv function (admittedly a non-working one),
    # which makes compiling (well, linking) Python easier.
    #
    # Additionally, 64-bit architectures only start existing at API level 21. If we want to decrease this
    # to 19, be sure to special-case 64-bit architectures to use 21.
    ANDROID_API_LEVEL=21
    # Compute the compiler name & binutils prefix name. Quoting https://developer.android.com/ndk/guides/other_build_systems :
    # "Note: For 32-bit ARM, the compiler is prefixed with armv7a-linux-androideabi, but the binutils tools are prefixed with arm-linux-androideabi. For other architectures, the prefixes are the same for all tools."
    case "${TARGET_ABI_SHORTNAME}" in
    armeabi-v7a)
        TOOLCHAIN_TRIPLE="arm-linux-androideabi"
        COMPILER_TRIPLE="armv7a-linux-androideabi${ANDROID_API_LEVEL}"
        ;;
    arm64-v8a)
        TOOLCHAIN_TRIPLE="aarch64-linux-android"
        COMPILER_TRIPLE="${TOOLCHAIN_TRIPLE}${ANDROID_API_LEVEL}"
        ;;
    x86)
        TOOLCHAIN_TRIPLE="i686-linux-android"
        COMPILER_TRIPLE="${TOOLCHAIN_TRIPLE}${ANDROID_API_LEVEL}"
        ;;
    x86_64)
        TOOLCHAIN_TRIPLE="x86_64-linux-android"
        COMPILER_TRIPLE="${TOOLCHAIN_TRIPLE}${ANDROID_API_LEVEL}"
        ;;
    esac
    # Compute the OpenSSL build target name.
    case "${TARGET_ABI_SHORTNAME}" in
    armeabi-v7a)
        OPENSSL_BUILD_TARGET="linux-generic32"
        ;;
    arm64-v8a)
        OPENSSL_BUILD_TARGET="linux-aarch64"
        ;;
    x86)
        OPENSSL_BUILD_TARGET="linux-x86"
        ;;
    x86_64)
        OPENSSL_BUILD_TARGET="linux-x86_64"
        ;;
    esac
    TAG_FOR_THIS_BUILD="local_$(python3 -c 'import time; print(int(time.time() * 1e9))')"
    IMAGE_NAME="python-android-support-3.7:${TAG_FOR_THIS_BUILD}"
    docker build --build-arg COMPILER_TRIPLE="${COMPILER_TRIPLE}" --build-arg OPENSSL_BUILD_TARGET="$OPENSSL_BUILD_TARGET" --build-arg TARGET_ABI_SHORTNAME="$TARGET_ABI_SHORTNAME" --build-arg TOOLCHAIN_TRIPLE="$TOOLCHAIN_TRIPLE" --build-arg ANDROID_API_LEVEL="$ANDROID_API_LEVEL" -t "$IMAGE_NAME" -f 3.7.Dockerfile .
    # Using rsync -L so that libpython3.7.so.1.0.0 is copied into a file, not as a symlink.
    docker run -v $PWD/output/3.7/:/mnt/ --rm --entrypoint rsync "$IMAGE_NAME" -aL /opt/python-build/approot/. /mnt/.
    docker run -v $PWD/output/3.7/:/mnt/ --rm --entrypoint rsync "$IMAGE_NAME" -aL /opt/python-build/built/python/include/python3.7m/pyconfig.h /mnt/
done
