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
# Do our Python build work here
ENV BUILD_HOME "/opt/python-build"
ENV PYTHON_INSTALL_DIR="$BUILD_HOME/built/python"
WORKDIR /opt/python-build

# Configure build variables
ENV HOST_TAG="linux-x86_64"
ARG TARGET_ABI_SHORTNAME
ENV TARGET_ABI_SHORTNAME $TARGET_ABI_SHORTNAME
ARG ANDROID_API_LEVEL
ENV ANDROID_API_LEVEL $ANDROID_API_LEVEL
ENV JNI_LIBS $APPROOT/app/libs/${TARGET_ABI_SHORTNAME}
ARG TOOLCHAIN_TRIPLE
ENV TOOLCHAIN_TRIPLE $TOOLCHAIN_TRIPLE
ENV TOOLCHAIN=$NDK/toolchains/llvm/prebuilt/$HOST_TAG
ARG COMPILER_TRIPLE
ENV COMPILER_TRIPLE=$COMPILER_TRIPLE
ENV AR=$TOOLCHAIN/bin/$TOOLCHAIN_TRIPLE-ar \
    AS=$TOOLCHAIN/bin/$TOOLCHAIN_TRIPLE-as \
    CC=$TOOLCHAIN/bin/${COMPILER_TRIPLE}-clang \
    CXX=$TOOLCHAIN/bin/${COMPILER_TRIPLE}-clang++ \
    LD=$TOOLCHAIN/bin/$TOOLCHAIN_TRIPLE-ld \
    RANLIB=$TOOLCHAIN/bin/$TOOLCHAIN_TRIPLE-ranlib \
    STRIP=$TOOLCHAIN/bin/$TOOLCHAIN_TRIPLE-strip \
    READELF=$TOOLCHAIN/bin/$TOOLCHAIN_TRIPLE-readelf \
    CFLAGS="-fPIC -Wall -O0 -g"

FROM toolchain as build_openssl
# OpenSSL requires libfindlibs-libs-perl. make is nice, too.
RUN apt-get update -qq && apt-get -qq install libfindbin-libs-perl make
RUN wget -q https://www.openssl.org/source/openssl-1.1.1d.tar.gz && sha256sum openssl-1.1.1d.tar.gz | grep -q 1e3a91bc1f9dfce01af26026f856e064eab4c8ee0a8f457b5ae30b40b8b711f2 && tar xf openssl-1.1.1d.tar.gz && rm -rf openssl-1.1.1d.tar.gz
ARG OPENSSL_BUILD_TARGET
RUN cd openssl-1.1.1d && ANDROID_NDK_HOME="$NDK" ./Configure ${OPENSSL_BUILD_TARGET} -D__ANDROID_API__="$ANDROID_API_LEVEL" --prefix="$BUILD_HOME/built/openssl" --openssldir="$BUILD_HOME/built/openssl"
RUN cd openssl-1.1.1d && make SHLIB_EXT='${SHLIB_VERSION_NUMBER}.so'
RUN cd openssl-1.1.1d && make install SHLIB_EXT='${SHLIB_VERSION_NUMBER}.so'
RUN ls -l $BUILD_HOME/built/openssl/lib

# This build container builds Python, rubicon-java, and any dependencies.
FROM toolchain as build_python

# Install libffi, required for ctypes.
RUN apt-get update -qq && apt-get -qq install file make
RUN wget -q https://github.com/libffi/libffi/releases/download/v3.3/libffi-3.3.tar.gz && tar xf libffi-3.3.tar.gz && rm libffi-3.3.tar.gz
ENV LIBFFI_INSTALL_DIR="$BUILD_HOME/built/libffi"
RUN mkdir -p "$LIBFFI_INSTALL_DIR" && \
    cd libffi-3.3 && \
    ./configure --host "$TOOLCHAIN_TRIPLE" --build "$COMPILER_TRIPLE" --prefix="$LIBFFI_INSTALL_DIR" && \
    make clean install && mkdir -p "$JNI_LIBS" && cp "$LIBFFI_INSTALL_DIR"/lib/libffi*so "$JNI_LIBS"
ENV PKG_CONFIG_PATH="$LIBFFI_INSTALL_DIR/lib/pkgconfig"

# Get OpenSSL from earlier build phase
# Copy OpenSSL from previous stage
COPY --from=build_openssl /opt/python-build/built/openssl /opt/python-build/built/openssl
ENV OPENSSL_INSTALL_DIR=/opt/python-build/built/openssl
# Remove the .1.1 symlinks, because maybe they confuse Android.
RUN cp -a "$OPENSSL_INSTALL_DIR"/lib/*.so "$JNI_LIBS"

# Download & patch Python
RUN apt-get update -qq && apt-get -qq install python3.7 pkg-config git zip xz-utils
RUN wget -q https://www.python.org/ftp/python/3.7.6/Python-3.7.6.tar.xz && tar xf Python-3.7.6.tar.xz && rm Python-3.7.6.tar.xz
# Modify ./configure so that, even though this is Linux, it does not append .1.0 to the .so file.
RUN sed -i -e 's,INSTSONAME="$LDLIBRARY".$SOVERSION,,' Python-3.7.6/configure
# Apply a C extensions linker hack; already fixed in Python 3.8+; see https://github.com/python/cpython/commit/254b309c801f82509597e3d7d4be56885ef94c11
RUN sed -i -e s,'libraries or \[\],\["python3.7m"] + libraries if libraries else \["python3.7m"\],' Python-3.7.6/Lib/distutils/extension.py
# Apply a hack to get the NDK library paths into the Python build. TODO(someday): Discuss with e.g. Kivy and see how to remove this.
RUN sed -i -e "s# dirs = \[\]# dirs = \[os.environ.get('NDK') + \"/sysroot/usr/include\", os.environ.get('TOOLCHAIN') + \"/sysroot/usr/lib/\" + os.environ.get('COMPILER_TRIPLE')\]#" Python-3.7.6/setup.py
# Apply a hack to make platform.py stop looking for a libc version.
RUN sed -i -e "s#Linux#DisabledLinuxCheck#" Python-3.7.6/Lib/platform.py

# Build Python, pre-configuring some values so it doesn't check if those exist.
RUN cd Python-3.7.6 && LDFLAGS="$(pkg-config --libs-only-L libffi) -L$OPENSSL_INSTALL_DIR/lib" \
    ./configure --host "$TOOLCHAIN_TRIPLE" --build "$COMPILER_TRIPLE" --enable-shared \
    --enable-ipv6 ac_cv_file__dev_ptmx=yes \
    --with-openssl=$OPENSSL_INSTALL_DIR \
    ac_cv_file__dev_ptc=no --without-ensurepip ac_cv_little_endian_double=yes \
    --prefix="$PYTHON_INSTALL_DIR" \
    ac_cv_func_setuid=no ac_cv_func_seteuid=no ac_cv_func_setegid=no ac_cv_func_getresuid=no ac_cv_func_setresgid=no ac_cv_func_setgid=no ac_cv_func_sethostname=no ac_cv_func_setresuid=no ac_cv_func_setregid=no ac_cv_func_setreuid=no ac_cv_func_getresgid=no ac_cv_func_setregid=no ac_cv_func_clock_settime=no ac_cv_header_termios_h=no ac_cv_func_sendfile=no ac_cv_header_spawn_h=no ac_cv_func_posix_spawn=no \
    ac_cv_func_setlocale=no ac_cv_working_tzset=no ac_cv_member_struct_tm_tm_zone=no
# Override ./configure results to futher force Python not to use some libc calls that trigger blocked syscalls.
# TODO(someday): See if HAVE_INITGROUPS has another way to disable it.
RUN cd Python-3.7.6 && sed -i -E 's,#define (HAVE_CHROOT|HAVE_SETGROUPS|HAVE_INITGROUPS) 1,,' pyconfig.h
# Override posixmodule.c assumption that fork & exec exist & work.
RUN cd Python-3.7.6 && sed -i -E 's,#define.*(HAVE_EXECV|HAVE_FORK).*1,,' Modules/posixmodule.c
# Compile Python. We can still remove some tests from the test suite before `make install`.
RUN cd Python-3.7.6 && make

# Modify stdlib & test suite before `make install`.

# Apply a hack to ctypes so that it loads libpython.so, even though this isn't Windows.
RUN sed -i -e 's,pythonapi = PyDLL(None),pythonapi = PyDLL("libpython3.7m.so"),' Python-3.7.6/Lib/ctypes/__init__.py
# Hack the test suite so that when it tries to remove files, if it can't remove them, the error passes silently.
# To see if ths is still an issue, run `test_bdb`.
RUN sed -i -e "s#NotADirectoryError#NotADirectoryError, OSError#" Python-3.7.6/Lib/test/support/__init__.py
# Ignore some tests
ADD 3.7.ignore_some_tests.py .
RUN python3.7 3.7.ignore_some_tests.py $(find Python-3.7.6/Lib/test -iname '*.py') $(find Python-3.7.6/Lib/distutils/tests -iname '*.py') $(find Python-3.7.6/Lib/unittest/test/ -iname '*.py') $(find Python-3.7.6/Lib/lib2to3/tests -iname '*.py')
# TODO(someday): restore signal tests & fix them
RUN cd Python-3.7.6 && rm Lib/test/test_signal.py Lib/test/test_threadsignals.py
# TODO(someday): restore asyncio tests & fix them
RUN cd Python-3.7.6 && rm -rf Lib/test/test_asyncio
# TODO(someday): restore subprocess tests & fix them
RUN cd Python-3.7.6 && rm Lib/test/test_subprocess.py
# TODO(someday): Restore test_httpservers tests. They depend on os.setuid() existing, and they have
# little meaning in Android.
RUN cd Python-3.7.6 && rm Lib/test/test_httpservers.py
# TODO(someday): restore xmlrpc tests & fix them; right now they hang forever.
RUN cd Python-3.7.6 && rm Lib/test/test_xmlrpc.py
# TODO(someday): restore wsgiref tests & fix them; right now they hang forever.
RUN cd Python-3.7.6 && rm Lib/test/test_wsgiref.py

# Install Python.
RUN cd Python-3.7.6 && make install
RUN cp -a $PYTHON_INSTALL_DIR/lib/libpython3.7m.so "$JNI_LIBS"
ENV ASSETS_DIR $APPROOT/app/src/main/assets/
RUN mkdir -p "$ASSETS_DIR" && cd "$PYTHON_INSTALL_DIR" && zip -0 -q "$ASSETS_DIR"/pythonhome.${TARGET_ABI_SHORTNAME}.zip -r .

# Download & install rubicon-java.
RUN git clone -b cross-compile https://github.com/paulproteus/rubicon-java.git && \
    cd rubicon-java && \
    LDFLAGS='-landroid -llog' PYTHON_CONFIG=$PYTHON_INSTALL_DIR/bin/python3-config make
RUN mv rubicon-java/dist/librubicon.so $JNI_LIBS
RUN mkdir -p /opt/python-build/app/libs/ && mv rubicon-java/dist/rubicon.jar $APPROOT/app/libs/
RUN cd rubicon-java && zip -0 -q "$ASSETS_DIR"/rubicon.zip -r rubicon

# Add rsync, which is used by `3.7.sh` to copy the data out of the container.
RUN apt-get update -qq && apt-get -qq install rsync
