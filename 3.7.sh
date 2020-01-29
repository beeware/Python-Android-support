#!/bin/bash

# Set bash strict mode.
set -eou pipefail

# Check dependencies.
function require() {
    local FOUND="no"
    which "$1" > /dev/null && FOUND="yes"
    if [ "$FOUND" = "no" ] ; then
	echo "Missing dependency: $1

Please install it. One of following might work, depending on your system:

$ sudo apt-get install $1
$ brew install $1

Exiting."
	exit 1
    fi
}

for dependency in docker python3 zip; do
    require "$dependency"
done

# Extract image ID from `docker build` output. Used by `build_one_abi`.
IMAGE_NAME_TEMPFILE="$(mktemp)"
function extract_image_name() {
    tee >(tail -n1 | sed -e 's,Successfully built \([^ ]*\),\1,' > "$IMAGE_NAME_TEMPFILE")
}

function build_one_abi() {
    TARGET_ABI_SHORTNAME="$1"
    # Using ANDROID_API_LEVEL=21 for two reasons:
    #
    # - >= 21 gives us a `localeconv` libc function (admittedly a
    #   non-working one), which makes compiling (well, linking) Python
    #   easier.
    #
    # - 64-bit architectures only start existing at API level 21.
    ANDROID_API_LEVEL=21
    # Compute the compiler name & binutils prefix name. See also:
    # https://developer.android.com/ndk/guides/other_build_systems

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

    # Compute OpenSSL build target name. We avoid using OpenSSL's built-in
    # Android support because it does not seem to give us any benefits.
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

    docker build --build-arg COMPILER_TRIPLE="${COMPILER_TRIPLE}" --build-arg OPENSSL_BUILD_TARGET="$OPENSSL_BUILD_TARGET" --build-arg TARGET_ABI_SHORTNAME="$TARGET_ABI_SHORTNAME" --build-arg TOOLCHAIN_TRIPLE="$TOOLCHAIN_TRIPLE" --build-arg ANDROID_API_LEVEL="$ANDROID_API_LEVEL" -f 3.7.Dockerfile . | extract_image_name
    local IMAGE_NAME
    IMAGE_NAME="$(cat $IMAGE_NAME_TEMPFILE)"
    if [ -z "$IMAGE_NAME" ] ; then
	echo 'Unable to find image name. Did Docker build succeed? Aborting.'
	exit 1
    fi

    # Using rsync -L so that libpython3.7.so.1.0.0 is copied into a file, not as a symlink.
    docker run -v $PWD/output/3.7/:/mnt/ --rm --entrypoint rsync "$IMAGE_NAME" -aL  /opt/python-build/approot/. /mnt/.
    docker run -v $PWD/output/3.7/:/mnt/ --rm --entrypoint rsync "$IMAGE_NAME" -aL /opt/python-build/built/python/include/python3.7m/pyconfig.h /mnt/
}

function main() {
    # Clear the output directory.
    rm -rf ./output/3.7
    mkdir -p output/3.7

    for TARGET_ABI_SHORTNAME in x86 x86_64 armeabi-v7a arm64-v8a; do
	build_one_abi "$TARGET_ABI_SHORTNAME"
    done

    # When using Docker on Linux, the `rsync` command creates files owned by root.
    # Compute the user ID and group ID of this script on the non-Docker side, and ask
    # Docker to adjust permissions accordingly.
    USER_AND_GROUP="$(id -u):$(id -g)"
    docker run -v $PWD/output/3.7/:/mnt/ --rm --entrypoint chown -R "$USER_AND_GROUP" .

    # Make a ZIP file.
    cd output/3.7 && zip -q -i 'app/*' -0 -r ../3.7.zip . && cd ../..
}

main
