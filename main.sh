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

    # We use Docker to run the build. We rely on Docker's build cache to allow the
    # build to be speedy if nothing changed, approx 1-2 seconds for a no-op build.
    # The cache persists even if no Docker "tags" point to the image.
    #
    # We do also use a temporary tag name so that we can use `rsync` to pull some
    # data out of the image.
    #
    # For debugging the Docker image, you can use the name python-android-support-local:latest.
    TAG_NAME="python-android-support-local:$(python3 -c 'import random; print(random.randint(0, 1e16))')"
    DOCKER_BUILDKIT=1 docker build --tag ${TAG_NAME} --tag python-android-support-local:latest \
        --build-arg PYTHON_VERSION="${PYTHON_VERSION}" \
        --build-arg COMPRESS_LEVEL="${COMPRESS_LEVEL}" --build-arg COMPILER_TRIPLE="${COMPILER_TRIPLE}" \
        --build-arg OPENSSL_BUILD_TARGET="$OPENSSL_BUILD_TARGET" --build-arg TARGET_ABI_SHORTNAME="$TARGET_ABI_SHORTNAME" \
        --build-arg TOOLCHAIN_TRIPLE="$TOOLCHAIN_TRIPLE" --build-arg ANDROID_API_LEVEL="$ANDROID_API_LEVEL" \
        -f python.Dockerfile .
    # Extract the build artifacts we need to create our zip file.
    docker run -v "${PWD}"/build/"${PYTHON_VERSION}"/:/mnt/ --rm --entrypoint rsync "$TAG_NAME" -a /opt/python-build/approot/. /mnt/.
    # Extract pyconfig.h for debugging ./configure strangeness.
    docker run -v "${PWD}"/build/"${PYTHON_VERSION}"/:/mnt/ --rm --entrypoint rsync "$TAG_NAME" -a /opt/python-build/built/python/include/python"${PYTHON_VERSION}"m/pyconfig.h /mnt/
    # Remove temporary local tag.
    docker rmi "$TAG_NAME" > /dev/null
    fix_permissions
}

# Download a file and verify its sha256sum.
function download_verify_sha256() {
    local url="$1"
    local sha256="$2"
    local filename_prefix="${3:-}"
    local DOWNLOAD_CACHE="$PWD/downloads"
    local DOWNLOAD_CACHE_TMP="$PWD/downloads.tmp"
    local expected_filename="${filename_prefix}$(echo "$url" | tr '/' '\n' | tail -n1)"

    # Check existing file.
    if [ -f "${DOWNLOAD_CACHE}/${expected_filename}" ] ; then
        echo "Using ${expected_filename} from downloads/"
        return
    fi

    echo "Downloading $expected_filename"
    rm -rf downloads.tmp && mkdir -p downloads.tmp
    curl -L "$url" -o "downloads.tmp/$expected_filename"
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
    local DEFAULT_VERSIONS="3.6,3.7"
    local VERSIONS="$DEFAULT_VERSIONS"
    local DEFAULT_TARGET_ABIS="x86,x86_64,armeabi-v7a,arm64-v8a"
    local TARGET_ABIS="$DEFAULT_TARGET_ABIS"
    local DEFAULT_COMPRESS_LEVEL="8"
    local COMPRESS_LEVEL="$DEFAULT_COMPRESS_LEVEL"
    local BUILD_NUMBER=""
    while getopts ":v:a:t:z:" opt; do
        case "${opt}" in
            v) # process Python version
                VERSIONS="$OPTARG"
                ;;
            a) # process Android ABIs
                TARGET_ABIS="$OPTARG"
                ;;
            t) # set build version name, used in BUILD_TAG
                BUILD_NUMBER="${OPTARG}"
                ;;
            z) # set compression level, passed to zip
                COMPRESS_LEVEL="${OPTARG}"
                ;;
            : )
                echo "Invalid option: $OPTARG requires an argument" 1>&2
                ;;
            \? )
                echo "Usage: main.sh [-v versions] [-a ABIs] [-n build_number] [-z compression_level]

Build ZIP file of Python resources for Android, including CPython compiled as a .so.

-v: Specify Python versions to build, separated by commas. For example: -v 3.6,3.7
    Default: ${DEFAULT_VERSIONS}

-a: Specify Android ABIs to build, separated by commas. For example: -a x86,arm64-v8a
    Default: ${TARGET_ABIS}

-n: Specify build number. If specified, this gets added to the filename prepended by a dot.
    For example, -n b5 would create Python-3.6-Android-support.b5.zip when building Python 3.6.
    By default, e.g. for Python 3.6, we generate the file Python-3.6-Android-support.zip.

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
        BUILD_TAG=""
    else
        echo "Building ${BUILD_NUMBER}"
        BUILD_TAG=".${BUILD_NUMBER}"
    fi

    echo "Downloading compile-time dependencies."

    local build_dependencies=(
        "https://github.com/AdoptOpenJDK/openjdk8-binaries/releases/download/jdk8u242-b08/OpenJDK8U-jdk_x64_linux_hotspot_8u242b08.tar.gz=f39b523c724d0e0047d238eb2bb17a9565a60574cf651206c867ee5fc000ab43"
        "https://dl.google.com/android/repository/android-ndk-r20b-linux-x86_64.zip=8381c440fe61fcbb01e209211ac01b519cd6adf51ab1c2281d5daad6ca4c8c8c"
        "https://www.openssl.org/source/openssl-1.1.1f.tar.gz=186c6bfe6ecfba7a5b48c47f8a1673d0f3b0e5ba2e25602dd23b629975da3f35"
        "https://github.com/libffi/libffi/releases/download/v3.3/libffi-3.3.tar.gz=72fba7922703ddfa7a028d513ac15a85c8d54c8d67f55fa5a4802885dc652056"
        "https://tukaani.org/xz/xz-5.2.4.tar.gz=b512f3b726d3b37b6dc4c8570e137b9311e7552e8ccbab4d39d47ce5f4177145"
        "https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz=ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269"
        "http://archive.ubuntu.com/ubuntu/pool/main/s/sqlite3/sqlite3_3.11.0.orig.tar.xz=79fb8800b8744337d5317270899a5a40612bb76f81517e131bf496c26b044490"
    )
    for build_dependency in "${build_dependencies[@]}" ; do
        download_verify_sha256 ${build_dependency/=/ }
    done

    # Download rubicon-java source tarball with a rubicon-java-* filename prefix. This allows the
    # Dockerfile to find it as rubicon-java-*.tar.gz . Other tarballs don't need this treatment
    # because they have the project name in the filename.
    download_verify_sha256 "https://github.com/beeware/rubicon-java/archive/v0.2.0.tar.gz" "b0d3d9ad4988c2d0e6995e2cbec085a5ef49b15e1be0d325b6141fb90fccccf7" "rubicon-java-"

    echo "Downloading Python versions, as needed."
    for version in ${VERSIONS//,/ } ; do
        if [ "$version" = "3.7" ] ; then
            download_verify_sha256 "https://www.python.org/ftp/python/3.7.6/Python-3.7.6.tar.xz" "55a2cce72049f0794e9a11a84862e9039af9183603b78bc60d89539f82cf533f"
        elif [ "$version" = "3.6" ] ; then
            download_verify_sha256 "https://www.python.org/ftp/python/3.6.10/Python-3.6.10.tar.xz" "0a833c398ac8cd7c5538f7232d8531afef943c60495c504484f308dac3af40de"
        else
            echo "Unknown Python version: $version. Aborting."
            exit 1
        fi
    done

    echo 'Starting Docker builds.'
    for VERSION in ${VERSIONS//,/ } ; do
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
    done
}

main "$@"
