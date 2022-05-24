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

function build_one_abi() {
    TARGET_ABI_SHORTNAME="$1"
    PYTHON_VERSION="$2"
    COMPRESS_LEVEL="$3"

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

    local PYTHON_SOVERSION="${PYTHON_VERSION}"
    local PYTHON_EXTRA_CONFIGURE_FLAGS=""
    if [ "$PYTHON_VERSION" = "3.7" ] ; then
        # 3.7 uses 3.7m
        PYTHON_SOVERSION="${PYTHON_VERSION}m"
    fi

    if [ "$PYTHON_VERSION" = "3.11" ] ; then
        # 3.11 requires --with-build-python
        PYTHON_EXTRA_CONFIGURE_FLAGS="--with-build-python=python3.11"
    fi

    # We use Docker to run the build. We rely on Docker's build cache to allow the
    # build to be speedy if nothing changed, approx 1-2 seconds for a no-op build.
    # The cache persists even if no Docker "tags" point to the image.
    #
    # We do also use a temporary tag name so that we can use `rsync` to pull some
    # data out of the image.
    #
    # For debugging the Docker image, you can use the name python-android-support-local:latest.
    TAG_NAME="python-android-support-local:$(python3 -c 'import random; print(random.randint(0, 1e16))')"
    DOCKER_BUILDKIT=1 docker build --platform linux/amd64 --tag ${TAG_NAME} --tag python-android-support-local:latest \
        --build-arg PYTHON_VERSION="${PYTHON_VERSION}" --build-arg PYTHON_SOVERSION="${PYTHON_SOVERSION}" \
        --build-arg COMPRESS_LEVEL="${COMPRESS_LEVEL}" --build-arg COMPILER_TRIPLE="${COMPILER_TRIPLE}" \
        --build-arg OPENSSL_BUILD_TARGET="$OPENSSL_BUILD_TARGET" --build-arg TARGET_ABI_SHORTNAME="$TARGET_ABI_SHORTNAME" \
        --build-arg TOOLCHAIN_TRIPLE="$TOOLCHAIN_TRIPLE" --build-arg ANDROID_API_LEVEL="$ANDROID_API_LEVEL" \
        --build-arg PYTHON_EXTRA_CONFIGURE_FLAGS="$PYTHON_EXTRA_CONFIGURE_FLAGS" \
        -f python.Dockerfile .
    # Extract the build artifacts we need to create our zip file.
    docker run -v "${PWD}"/build/"${PYTHON_VERSION}"/:/mnt/ --rm --entrypoint rsync "$TAG_NAME" -a /opt/python-build/approot/. /mnt/.
    # Extract header files
    docker run -v "${PWD}"/build/"${PYTHON_VERSION}"/app/include/:/mnt/ --rm --entrypoint rsync "$TAG_NAME" -a /opt/python-build/built/python/include/ /mnt/

    # Docker creates files as root; reown as the local user
    fix_permissions

    # Move pyconfig.h to a platform-specific name.
    mv "${PWD}"/build/"${PYTHON_VERSION}"/app/include/python"${PYTHON_SOVERSION}"/pyconfig.h "${PWD}"/build/"${PYTHON_VERSION}"/app/include/python"${PYTHON_SOVERSION}"/pyconfig-${TARGET_ABI_SHORTNAME}.h
    # Inject a platform-agnostic pyconfig.h wrapper.
    cp "${PWD}/patches/all/pyconfig.h" "${PWD}"/build/"${PYTHON_VERSION}"/app/include/python"${PYTHON_SOVERSION}"/
    # Remove temporary local tag.
    docker rmi "$TAG_NAME" > /dev/null
}

# Download a file into downloads/$name/$filename and verify its sha256sum.
# If any files exist under downloads/$name, remove them. In the Dockerfile,
# we refer to the tarball as downloads/$name/* , allowing the Dockerfile
# to avoid redundantly stating the version number.
function download() {
    local name="$1"
    local url="$2"
    local sha256="$3"
    local download_dir="${PWD}/downloads/$name"
    local base_filename="$(echo "$url" | tr '/' '\n' | tail -n1)"
    local full_filename="$download_dir/$base_filename"
    local full_filename_tmp="${full_filename}.tmp"

    # Check existing file.
    if [ -f "${full_filename}" ] ; then
        echo "Using $name (${full_filename})"
        return
    fi

    echo "Downloading $name ($full_filename)"
    rm -rf "$download_dir"
    mkdir -p "$download_dir"
    curl -L "$url" -o "$full_filename_tmp"
    local OK="no"
    local actual_sha256=$(shasum -a 256 "${full_filename_tmp}")
    echo $actual_sha256 | grep -q "$sha256" && OK="yes"
    if [ "$OK" = "yes" ] ; then
        mv "${full_filename_tmp}" "${full_filename}"
    else
        echo "Checksum mismatch while downloading $name <$url>"
        echo "Expected: $sha256"
        echo "     Got: $actual_sha256"
        echo ""
        echo "Maybe your Internet connection got disconnected during the download. Re-run"
        echo "the script to re-download. If you're updating the version of this package"
        echo "update the expected SHA in this script."
        echo "Partial file remains in: ${full_filename_tmp}"
        echo "Aborting."
        exit 1
    fi
}

fix_permissions() {
    local USER_AND_GROUP="$(id -u):$(id -g)"
    # When using Docker on Linux, the `rsync` command creates files owned by root.
    # Compute the user ID and group ID of this script on the non-Docker side, and ask
    # Docker to adjust permissions accordingly.
    docker run -v "${PWD}":/mnt/ --rm --entrypoint chown ubuntu:18.04 -R "$USER_AND_GROUP" /mnt/build/
}

function main() {
    # Interpret argv for settings; first, set defaults. For some settings, create
    # DEFAULT_* variables for inclusion into help output.
    local DEFAULT_VERSION="3.7"
    local VERSION="$DEFAULT_VERSION"
    local DEFAULT_TARGET_ABIS="x86_64,arm64-v8a"
    local TARGET_ABIS="$DEFAULT_TARGET_ABIS"
    local DEFAULT_COMPRESS_LEVEL="8"
    local COMPRESS_LEVEL="$DEFAULT_COMPRESS_LEVEL"
    local BUILD_NUMBER=""
    while getopts ":v:a:n:z:" opt; do
        case "${opt}" in
            v) # process Python version
                VERSION="$OPTARG"
                ;;
            a) # process Android ABIs
                TARGET_ABIS="$OPTARG"
                ;;
            n) # set build version name, used in BUILD_TAG
                BUILD_NUMBER="${OPTARG}"
                ;;
            z) # set compression level, passed to zip
                COMPRESS_LEVEL="${OPTARG}"
                ;;
            : )
                echo "Invalid option: $OPTARG requires an argument" 1>&2
                ;;
            \? )
                echo "Usage: main.sh [-v version] [-a ABIs] [-n build_number] [-z compression_level]

Build ZIP file of Python resources for Android, including CPython compiled as a .so.

-v: Specify Python version to build. For example: -v 3.7
    Default: ${DEFAULT_VERSION}

-a: Specify Android ABIs to build, separated by commas. For example: -a x86,arm64-v8a
    Default: ${TARGET_ABIS}

-n: Specify build number. If specified, this gets added to the filename prepended by a dot.
    For example, -n b5 would create Python-3.X-Android-support.b5.zip when building Python 3.X.
    By default, e.g. for Python 3.X, we generate the file Python-3.X-Android-support.custom.zip.

-z: Specify compression level to use when creating ZIP files. For example, -z 0 is fastest.
    Default: ${DEFAULT_COMPRESS_LEVEL}
" 1>&2
                exit 1
                ;;
        esac
    done

    local BUILD_TAG
    if [ -z "${BUILD_NUMBER:-}" ]; then
        echo "Building untagged build"
        BUILD_TAG=".custom"
    else
        echo "Building ${BUILD_NUMBER}"
        BUILD_TAG=".${BUILD_NUMBER}"
    fi

    echo "Downloading compile-time dependencies."

    download jdk "https://github.com/AdoptOpenJDK/openjdk8-binaries/releases/download/jdk8u242-b08/OpenJDK8U-jdk_x64_linux_hotspot_8u242b08.tar.gz" "f39b523c724d0e0047d238eb2bb17a9565a60574cf651206c867ee5fc000ab43"
    download ndk "https://dl.google.com/android/repository/android-ndk-r23b-linux.zip" "c6e97f9c8cfe5b7be0a9e6c15af8e7a179475b7ded23e2d1c1fa0945d6fb4382"
    download openssl "https://www.openssl.org/source/openssl-1.1.1o.tar.gz" "9384a2b0570dd80358841464677115df785edb941c71211f75076d72fe6b438f"
    download libffi "https://github.com/libffi/libffi/releases/download/v3.3/libffi-3.3.tar.gz" "72fba7922703ddfa7a028d513ac15a85c8d54c8d67f55fa5a4802885dc652056"
    download xz "https://tukaani.org/xz/xz-5.2.5.tar.gz" "f6f4910fd033078738bd82bfba4f49219d03b17eb0794eb91efbae419f4aba10"
    download bzip2 "https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz" "ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269"
    download sqlite3 "https://github.com/sqlite/sqlite/archive/refs/tags/version-3.35.0.zip" "f85ba70e340428fbf45ed1bf390ddcc622c7f8f4b30e60d063c6b6f8d78924ae"
    download rubicon-java "https://github.com/beeware/rubicon-java/archive/v0.2.6.tar.gz" "0386d84182b347c0e64947579c3e853e9b72d375094fa6d00942f9a7635ca6d1"

    echo "Downloading Python version."
    case "$VERSION" in
        3.7)
            download "python-3.7" "https://www.python.org/ftp/python/3.7.13/Python-3.7.13.tar.xz" "99f106275df8899c3e8cb9d7c01ce686c202ef275953301427194693de5bef84"
            ;;
        3.8)
            download "python-3.8" "https://www.python.org/ftp/python/3.8.13/Python-3.8.13.tar.xz" "6f309077012040aa39fe8f0c61db8c0fa1c45136763299d375c9e5756f09cf57"
            ;;
        3.9)
            download "python-3.9" "https://www.python.org/ftp/python/3.9.12/Python-3.9.12.tar.xz" "2cd94b20670e4159c6d9ab57f91dbf255b97d8c1a1451d1c35f4ec1968adf971"
            ;;
        3.10)
            download "python-3.10" "https://www.python.org/ftp/python/3.10.4/Python-3.10.4.tar.xz" "80bf925f571da436b35210886cf79f6eb5fa5d6c571316b73568343451f77a19"
            ;;
        3.11)
            download "python-3.11" "https://www.python.org/ftp/python/3.11.0/Python-3.11.0b1.tar.xz" "dccac9b03dd3fe5cd10bc547579eb0be81a1d8971ec2a866b03dec5391f5ad25"
            ;;
        *)
            echo "Invalid Python version: $VERSION"
            exit 1
            ;;
    esac

    echo 'Starting Docker builds.'

    # Clear the build directory.
    mkdir -p build
    mkdir -p dist
    fix_permissions
    rm -rf ./build/"$VERSION"
    mkdir -p build/"$VERSION"

    # Build each ABI.
    for TARGET_ABI_SHORTNAME in ${TARGET_ABIS//,/ }; do
        echo "Building Python $VERSION for $TARGET_ABI_SHORTNAME"
        build_one_abi "$TARGET_ABI_SHORTNAME" "$VERSION" "$COMPRESS_LEVEL"
    done

    # Make a ZIP file, writing it first to `.tmp` so that we atomically clobber an
    # existing ZIP file rather than attempt to merge the new contents with old.
    pushd build/"$VERSION"/app > /dev/null
    zip -x@../../../excludes/all/excludes -r -"${COMPRESS_LEVEL}" "../../../dist/Python-$VERSION-Android-support${BUILD_TAG}.zip".tmp .
    mv "../../../dist/Python-$VERSION-Android-support${BUILD_TAG}.zip".tmp "../../../dist/Python-$VERSION-Android-support${BUILD_TAG}.zip"
    popd
}

main "$@"
