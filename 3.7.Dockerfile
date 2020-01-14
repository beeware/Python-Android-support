# This toolchain container, set up at the start of the Dockerfile, encodes environment variables &
# downloads essential dependencies.
FROM ubuntu:18.04 as toolchain
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get -qq install wget unzip xz-utils

# Install toolchains: Android NDK & Java JDK.
WORKDIR /opt/ndk
RUN wget -q https://dl.google.com/android/repository/android-ndk-r20b-linux-x86_64.zip && unzip -q android-ndk-r20b-linux-x86_64.zip && rm android-ndk-r20b-linux-x86_64.zip
ENV NDK /opt/ndk/android-ndk-r20b
WORKDIR /opt/jdk
RUN wget -q https://github.com/AdoptOpenJDK/openjdk11-binaries/releases/download/jdk-11.0.5%2B10/OpenJDK11U-jdk_x64_linux_hotspot_11.0.5_10.tar.gz && tar xf OpenJDK11U-jdk_x64_linux_hotspot_11.0.5_10.tar.gz && rm OpenJDK11U-jdk_x64_linux_hotspot_11.0.5_10.tar.gz
ENV JAVA_HOME /opt/jdk/jdk-11.0.5+10/
ENV PATH "/opt/jdk/jdk-11.0.5+10/bin:${PATH}"

# Store output here; the directory structure corresponds to our Android app template.
ENV APPROOT /opt/python-build/approot
ENV JNI_LIBS $APPROOT/app/libs/x86_64

# Configure build variables
ENV HOST_TAG="linux-x86_64"
ENV TARGET="x86_64-linux-android"
ENV ANDROID_SDK_VERSION="29"
ENV TOOLCHAIN=$NDK/toolchains/llvm/prebuilt/$HOST_TAG
ENV AR=$TOOLCHAIN/bin/$TARGET-ar \
    AS=$TOOLCHAIN/bin/$TARGET-as \
    CC=$TOOLCHAIN/bin/${TARGET}${ANDROID_SDK_VERSION}-clang \
    CXX=$TOOLCHAIN/bin/${TARGET}${ANDROID_SDK_VERSION}-clang++ \
    LD=$TOOLCHAIN/bin/$TARGET-ld \
    RANLIB=$TOOLCHAIN/bin/$TARGET-ranlib \
    STRIP=$TOOLCHAIN/bin/$TARGET-strip \
    READELF=$TOOLCHAIN/bin/$TARGET-readelf \
    CFLAGS="-fPIC -Wall -O0 -g"

# Do our Python build work here
ENV BUILD_HOME "/opt/python-build"
ENV PYTHON_INSTALL_DIR="$BUILD_HOME/built/python"
WORKDIR /opt/python-build

# This build container builds Python, rubicon-java, and any dependencies.
FROM toolchain as build

# Install libffi, required for ctypes.
RUN apt-get update -qq && apt-get -qq install file make
RUN wget -q https://github.com/libffi/libffi/releases/download/v3.3/libffi-3.3.tar.gz && tar xf libffi-3.3.tar.gz && rm libffi-3.3.tar.gz
ENV LIBFFI_INSTALL_DIR="$BUILD_HOME/built/libffi"
RUN mkdir -p "$LIBFFI_INSTALL_DIR" && \
    cd libffi-3.3 && \
    ./configure --host "$TARGET" --build "$TARGET""$ANDROID_SDK_VERSION" --prefix="$LIBFFI_INSTALL_DIR" && \
    make clean install && mkdir -p "$JNI_LIBS" && cp "$LIBFFI_INSTALL_DIR"/lib/libffi*so "$JNI_LIBS"
ENV PKG_CONFIG_PATH="$LIBFFI_INSTALL_DIR/lib/pkgconfig"

# Download & patch Python
RUN apt-get update -qq && apt-get -qq install python3.7 pkg-config git zip xz-utils
RUN wget -q https://www.python.org/ftp/python/3.7.6/Python-3.7.6.tar.xz && tar xf Python-3.7.6.tar.xz && rm Python-3.7.6.tar.xz
# Apply a C extensions linker hack; already fixed in Python 3.8+; see https://github.com/python/cpython/commit/254b309c801f82509597e3d7d4be56885ef94c11
RUN sed -i -e s,'libraries or \[\],\["python3.7m"] + libraries if libraries else \["python3.7m"\],' Python-3.7.6/Lib/distutils/extension.py
# Apply a hack to get the NDK library paths into the Python build. TODO(someday): Discuss with e.g. Kivy and see how to remove this.
RUN sed -i -e "s# dirs = \[\]# dirs = \[os.environ.get('NDK') + \"/sysroot/usr/include\", os.environ.get('TOOLCHAIN') + \"/sysroot/usr/lib/\" + os.environ.get('TARGET') + '/' + os.environ.get('ANDROID_SDK_VERSION')\]#" Python-3.7.6/setup.py
# Apply a hack to make platform.py stop looking for a libc version.
RUN sed -i -e "s#Linux#DisabledLinuxCheck#" Python-3.7.6/Lib/platform.py
# Hack the test suite so that when it tries to remove files, if it can't remove them, the error passes silently.
# To see if ths is still an issue, run `test_bdb`.
RUN sed -i -e "s#NotADirectoryError#NotADirectoryError, OSError#" Python-3.7.6/Lib/test/support/__init__.py
# Ignore some tests
ADD 3.7.ignore_some_tests.py .
RUN python3.7 3.7.ignore_some_tests.py $(find Python-3.7.6/Lib/test -iname '*.py') $(find Python-3.7.6/Lib/distutils/tests -iname '*.py') $(find Python-3.7.6/Lib/unittest/test/ -iname '*.py') $(find Python-3.7.6/Lib/lib2to3/tests -iname '*.py')

# Build Python, pre-configuring some values so it doesn't check if those exist.
RUN cd Python-3.7.6 && LDFLAGS=`pkg-config --libs-only-L libffi` \
  ./configure --host "$TARGET" --build "$TARGET""$ANDROID_SDK_VERSION" --enable-shared \
  --enable-ipv6 ac_cv_file__dev_ptmx=yes \
  ac_cv_file__dev_ptc=no --without-ensurepip ac_cv_little_endian_double=yes \
  --prefix="$PYTHON_INSTALL_DIR" \
  ac_cv_func_setuid=no ac_cv_func_seteuid=no ac_cv_func_setegid=no ac_cv_func_getresuid=no ac_cv_func_setresgid=no ac_cv_func_setgid=no ac_cv_func_sethostname=no ac_cv_func_setresuid=no ac_cv_func_setregid=no ac_cv_func_setreuid=no ac_cv_func_getresgid=no ac_cv_func_setregid=no ac_cv_func_clock_settime=no ac_cv_header_termios_h=no ac_cv_func_sendfile=no ac_cv_header_spawn_h=no ac_cv_func_waitpid=yes ac_cv_func_posix_spawn=no
# Override ./configure results to futher force Python not to use some libc calls that trigger blocked syscalls.
RUN cd Python-3.7.6 && sed -i -E 's,#define (HAVE_CHROOT|HAVE_SETGROUPS) 1,,' pyconfig.h
RUN cd Python-3.7.6 && make && make install
# Copy the entire Python install, including bin/python3 and the standard library, into a ZIP file we use as an app asset.
ENV ASSETS_DIR $APPROOT/app/src/main/assets/
RUN mkdir -p "$ASSETS_DIR" && cd "$PYTHON_INSTALL_DIR" && zip -0 -q "$ASSETS_DIR"/pythonhome.zip -r .
# Copy libpython into the app as a JNI library.
RUN cp -a $PYTHON_INSTALL_DIR/lib/*.so $PYTHON_INSTALL_DIR/lib/*.so.* "$JNI_LIBS"

# Download & install rubicon-java.
RUN git clone -b cross-compile https://github.com/paulproteus/rubicon-java.git && \
    cd rubicon-java && \
    LDFLAGS='-landroid -llog' PYTHON_CONFIG=$PYTHON_INSTALL_DIR/bin/python3-config make
RUN mv rubicon-java/dist/librubicon.so $JNI_LIBS
RUN mkdir -p /opt/python-build/app/libs/ && mv rubicon-java/dist/rubicon.jar $APPROOT/app/libs/
RUN cd rubicon-java && zip -0 -q "$ASSETS_DIR"/rubicon.zip -r rubicon

# Add rsync, which is used by `3.7.sh` to copy the data out of the container.
RUN apt-get update -qq && apt-get -qq install rsync
