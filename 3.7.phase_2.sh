# bash strict mode
set -eou pipefail
# Toolchain setup
export HOST_TAG="$(ls -1 $NDK/toolchains/llvm/prebuilt | head -n1)"
export TOOLCHAIN=$NDK/toolchains/llvm/prebuilt/$HOST_TAG
export TARGET="$1"
export ANDROID_SDK_VERSION=29
export AR=$TOOLCHAIN/bin/$TARGET-ar
export AS=$TOOLCHAIN/bin/$TARGET-as
export CC=$TOOLCHAIN/bin/${TARGET}${ANDROID_SDK_VERSION}-clang
export CXX=$TOOLCHAIN/bin/${TARGET}${ANDROID_SDK_VERSION}-clang++
export LD=$TOOLCHAIN/bin/$TARGET-ld
export RANLIB=$TOOLCHAIN/bin/$TARGET-ranlib
export STRIP=$TOOLCHAIN/bin/$TARGET-strip
export READELF=$TOOLCHAIN/bin/$TARGET-readelf
export CFLAGS="-fPIC -Wall -O0 -g"
export LDFLAGS='-landroid -llog'

# Create an applibs dir, where we collect all the libs we've built
APPLIBS="applibs/${TARGET}"
mkdir -p "$APPLIBS"

# Build libffi, so that we can have ctypes :)
cd libffi-3.3
./configure --host "$TARGET" --build "$TARGET""$ANDROID_SDK_VERSION" --prefix=$PWD/built
make clean install
cd ..

# Copy it into the app so that `ctypes` can use it
cp libffi-3.3/built/lib/libffi*so "$APPLIBS"

# Build Python
cd Python-3.7.6
LDFLAGS=`PKG_CONFIG_PATH="$PWD/../libffi-3.3/built/lib/pkgconfig" pkg-config --libs-only-L libffi` PKG_CONFIG_PATH="$PWD/../libffi-3.3/built/lib/pkgconfig" LD_LIBRARY_PATH="$PWD/../libffi-3.3/built" ./configure --host "$TARGET" --build "$TARGET""$ANDROID_SDK_VERSION" --enable-shared \
  --enable-ipv6 ac_cv_file__dev_ptmx=yes \
  ac_cv_file__dev_ptc=no --without-ensurepip ac_cv_little_endian_double=yes \
  --prefix=$PWD/built
make
make install
cd ..

# Copy the python .so into the app
cp $PWD/Python-3.7.6/built/lib/*.so "$APPLIBS"

# Zip up the Python stdlib, so the Android app can unpack it at startup.
pushd $PWD/Python-3.7.6/built
STDLIB_ZIP="$(mktemp -t python-tarball.XXXXXXXXXXX -d)/pythonhome.zip"
zip -q -r "$STDLIB_ZIP" .
popd

ASSETS="assets/${TARGET}"
mkdir -p "$ASSETS"
cp "$STDLIB_ZIP" "$ASSETS"
