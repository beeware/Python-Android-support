#!/bin/bash
# This script only uses bash features available in bash <= 3,
# so that it works the same on macOS and GNU/Linux.

# Set bash strict mode.
set -eou pipefail

# Check dependencies.
function require() {
    local FOUND="no"
    which "$1" >/dev/null && FOUND="yes"
    if [ "$FOUND" = "no" ]; then
        echo "Missing dependency: $1

Please install it. One of following might work, depending on your system:

$ sudo apt-get install $1
$ brew install $1

Exiting."
        exit 1
    fi
}

# We require `perl` because that is the the program that provides
# shasum; we use shasum because it's available easily on macOS &
# GNU/Linux.
for dependency in curl cut docker grep perl python3 shasum zip; do
    require "$dependency"
done

# Extract image ID from `docker build` output. Used by `build_one_abi`.
IMAGE_NAME_TEMPFILE="$(mktemp)"
function extract_image_name() {
    tee >(tail -n1 | grep '^Successfully built ' | cut -d' ' -f3 >"$IMAGE_NAME_TEMPFILE")
}

function build_one_abi() {
    TARGET_ABI_SHORTNAME="$1"
    PYTHON_VERSION="$2"
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

    docker build --build-arg COMPILER_TRIPLE="${COMPILER_TRIPLE}" --build-arg OPENSSL_BUILD_TARGET="$OPENSSL_BUILD_TARGET" --build-arg TARGET_ABI_SHORTNAME="$TARGET_ABI_SHORTNAME" --build-arg TOOLCHAIN_TRIPLE="$TOOLCHAIN_TRIPLE" --build-arg ANDROID_API_LEVEL="$ANDROID_API_LEVEL" -f "${PYTHON_VERSION}".Dockerfile . | extract_image_name
    local IMAGE_NAME
    IMAGE_NAME="$(cat $IMAGE_NAME_TEMPFILE)"
    if [ -z "$IMAGE_NAME" ]; then
        echo 'Unable to find image name. Did Docker build succeed? Aborting.'
        exit 1
    fi

    # Extract the build artifacts we need to create our zip file.
    docker run -v "${PWD}"/build/"${PYTHON_VERSION}"/:/mnt/ --rm --entrypoint rsync "$IMAGE_NAME" -a /opt/python-build/approot/. /mnt/.
    # Extract pyconfig.h for debugging ./configure strangeness.
    docker run -v "${PWD}"/build/"${PYTHON_VERSION}"/:/mnt/ --rm --entrypoint rsync "$IMAGE_NAME" -a /opt/python-build/built/python/include/python"${PYTHON_VERSION}"m/pyconfig.h /mnt/
    fix_permissions
}

function download() {
    # Pass -L to follow redirects.
    echo "Downloading $2"
    curl -L "$1" -o "$2"
}

# Store a bash associative array of URLs we download, and their expected SHA256 sum.
function download_urls() {
    echo "Preparing downloads..."
    URLS_AND_SHA256=(
        "https://github.com/AdoptOpenJDK/openjdk8-binaries/releases/download/jdk8u242-b08/OpenJDK8U-jdk_x64_linux_hotspot_8u242b08.tar.gz=f39b523c724d0e0047d238eb2bb17a9565a60574cf651206c867ee5fc000ab43"
        "https://dl.google.com/android/repository/android-ndk-r20b-linux-x86_64.zip=8381c440fe61fcbb01e209211ac01b519cd6adf51ab1c2281d5daad6ca4c8c8c"
        "https://www.openssl.org/source/openssl-1.1.1d.tar.gz=1e3a91bc1f9dfce01af26026f856e064eab4c8ee0a8f457b5ae30b40b8b711f2"
        "https://github.com/libffi/libffi/releases/download/v3.3/libffi-3.3.tar.gz=72fba7922703ddfa7a028d513ac15a85c8d54c8d67f55fa5a4802885dc652056"
        "https://www.python.org/ftp/python/3.7.6/Python-3.7.6.tar.xz=55a2cce72049f0794e9a11a84862e9039af9183603b78bc60d89539f82cf533f"
        "https://tukaani.org/xz/xz-5.2.4.tar.gz=b512f3b726d3b37b6dc4c8570e137b9311e7552e8ccbab4d39d47ce5f4177145"
        "https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz"="ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269"
        "http://archive.ubuntu.com/ubuntu/pool/main/s/sqlite3/sqlite3_3.11.0.orig.tar.xz"="79fb8800b8744337d5317270899a5a40612bb76f81517e131bf496c26b044490"
        "https://github.com/paulproteus/rubicon-java/archive/0.2020-02-27.0.tar.gz=b698c1f5fd3f8d825ed88e1a782f1aaa58f6d27404edc43fdb7dd117ab4c8f28"
    )
    local DOWNLOAD_CACHE="$PWD/downloads"
    local DOWNLOAD_CACHE_TMP="$PWD/downloads.tmp"
    for url_and_sha256 in "${URLS_AND_SHA256[@]}" ; do
        url="${url_and_sha256%%=*}"
        sha256="${url_and_sha256##*=}"
        expected_filename="$(echo "$url" | tr '/' '\n' | tail -n1)"
        # Check existing file.
        if [ -f "${DOWNLOAD_CACHE}/${expected_filename}" ] ; then
            echo "Using ${expected_filename} from downloads/"
            continue
        fi

        # Download.
        rm -rf downloads.tmp && mkdir -p downloads.tmp
        cd downloads.tmp && download "$url" "$expected_filename" && cd ..
        local OK="no"
        shasum -a 256 "${DOWNLOAD_CACHE_TMP}/${expected_filename}" | grep -q "$sha256" && OK="yes"
        if [ "$OK" = "yes" ] ; then
            mkdir -p "$DOWNLOAD_CACHE"
            mv "${DOWNLOAD_CACHE_TMP}/${expected_filename}" "${DOWNLOAD_CACHE}/${expected_filename}"
            rmdir "${DOWNLOAD_CACHE_TMP}"
        else
            echo "Checksum mismatch while downloading: $url"
            echo ""
            echo "Maybe your Internet connection got disconnected during the download. Please re-run the script."
            echo "Aborting."
            exit 1
        fi
    done
}

fix_permissions() {
    USER_AND_GROUP="$(id -u):$(id -g)"
    # When using Docker on Linux, the `rsync` command creates files owned by root.
    # Compute the user ID and group ID of this script on the non-Docker side, and ask
    # Docker to adjust permissions accordingly.
    docker run -v "${PWD}":/mnt/ --rm --entrypoint chown ubuntu:18.04 -R "$USER_AND_GROUP" /mnt/build/
}

function main() {
    echo 'Starting Docker builds.'

    if [ -z "${BUILD_NUMBER:-}" ]; then
        BUILD_TAG=""
        echo "Building untagged build"
    else
        BUILD_TAG=".b${BUILD_NUMBER}"
        echo "Building b${BUILD_NUMBER}"
    fi

    # Clear the build directory.
    mkdir -p build
    mkdir -p dist
    fix_permissions
    rm -rf ./build/3.7
    mkdir -p build/3.7

    # Allow TARGET_ABIs to be overridden by argv.
    TARGET_ABIS="${@:-x86 x86_64 armeabi-v7a arm64-v8a}"
    for TARGET_ABI_SHORTNAME in $TARGET_ABIS; do
        build_one_abi "$TARGET_ABI_SHORTNAME" "3.7"
    done

    # Make a ZIP file.
    fix_permissions
    cd build/3.7/app && zip -q -i '*' -r ../../../dist/Python-3.7-Android-support${BUILD_TAG}.zip . && cd ../../..
}

download_urls
main "$@"
