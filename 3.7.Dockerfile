# The toolchain container encodes environment
# downloads essential dependencies.
FROM ubuntu:18.04 as toolchain
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get -qq install unzip

# Install toolchains: Android NDK & Java JDK.
WORKDIR /opt/ndk
ADD downloads/android-ndk-r20b-linux-x86_64.zip .
RUN unzip -q android-ndk-r20b-linux-x86_64.zip && rm android-ndk-r20b-linux-x86_64.zip
ENV NDK /opt/ndk/android-ndk-r20b
WORKDIR /opt/jdk
ADD downloads/OpenJDK8U-jdk_x64_linux_hotspot_8u242b08.tar.gz .
ENV JAVA_HOME /opt/jdk/jdk8u242-b08/
ENV PATH "/opt/jdk/jdk8u242-b08/bin:${PATH}"

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

# We build sqlite using a tarball from Ubuntu. We need to patch config.sub & config.guess so
# autoconf can accept our weird TOOLCHAIN_TRIPLE value. It requires tcl8.6-dev and build-essential
# because the compile process build and executes some commands on the host as part of the build process.
# We hard-code avoid_version=yes into libtool so that libsqlite3.so is the SONAME.
FROM toolchain as build_sqlite
RUN apt-get update -qq && apt-get -qq install make autoconf autotools-dev tcl8.6-dev build-essential
ADD downloads/sqlite3_3.11.0.orig.tar.xz .
RUN cd sqlite3-3.11.0 && autoreconf && cp -f /usr/share/misc/config.sub . && cp -f /usr/share/misc/config.guess .
RUN cd sqlite3-3.11.0 && ./configure --host "$TOOLCHAIN_TRIPLE" --build "$COMPILER_TRIPLE" --prefix="$BUILD_HOME/built/sqlite"
RUN cd sqlite3-3.11.0 && sed -i -E 's,avoid_version=no,avoid_version=yes,' ltmain.sh libtool
RUN cd sqlite3-3.11.0 && make install

# Install bzip2 & lzma libraries, for stdlib's _bzip2 and _lzma modules.
FROM toolchain as build_xz
RUN apt-get update -qq && apt-get -qq install make
ADD downloads/xz-5.2.4.tar.gz .
ENV LIBXZ_INSTALL_DIR="$BUILD_HOME/built/xz"
RUN mkdir -p "$LIBXZ_INSTALL_DIR"
RUN cd xz-5.2.4 && ./configure --host "$TOOLCHAIN_TRIPLE" --build "$COMPILER_TRIPLE" --prefix="$LIBXZ_INSTALL_DIR"
RUN cd xz-5.2.4 && make install

FROM toolchain as build_bz2
RUN apt-get update -qq && apt-get -qq install make
ENV LIBBZ2_INSTALL_DIR="$BUILD_HOME/built/libbz2"
ADD downloads/bzip2-1.0.8.tar.gz .
RUN mkdir -p "$LIBBZ2_INSTALL_DIR" && \
    cd bzip2-1.0.8 && \
    sed -i -e 's,[.]1[.]0.8,,' -e 's,[.]1[.]0,,' -e 's,ln -s,#ln -s,' -e 's,rm -f libbz2.so,#rm -f libbz2.so,' -e 's,^CC=,#CC=,' Makefile-libbz2_so
RUN cd bzip2-1.0.8 && make -f Makefile-libbz2_so
RUN mkdir -p "${LIBBZ2_INSTALL_DIR}/lib"
RUN cp bzip2-1.0.8/libbz2.so "${LIBBZ2_INSTALL_DIR}/lib"
RUN mkdir -p "${LIBBZ2_INSTALL_DIR}/include"
RUN cp bzip2-1.0.8/bzlib.h "${LIBBZ2_INSTALL_DIR}/include"

# libffi is required by ctypes
FROM toolchain as build_libffi
RUN apt-get update -qq && apt-get -qq install file make
ADD downloads/libffi-3.3.tar.gz .
ENV LIBFFI_INSTALL_DIR="$BUILD_HOME/built/libffi"
RUN mkdir -p "$LIBFFI_INSTALL_DIR"
RUN cd libffi-3.3 && ./configure --host "$TOOLCHAIN_TRIPLE" --build "$COMPILER_TRIPLE" --prefix="$LIBFFI_INSTALL_DIR"
RUN cd libffi-3.3 && make install

FROM toolchain as build_openssl
# OpenSSL requires libfindlibs-libs-perl. make is nice, too.
RUN apt-get update -qq && apt-get -qq install libfindbin-libs-perl make
ADD downloads/openssl-1.1.1d.tar.gz .
ARG OPENSSL_BUILD_TARGET
RUN cd openssl-1.1.1d && ANDROID_NDK_HOME="$NDK" ./Configure ${OPENSSL_BUILD_TARGET} -D__ANDROID_API__="$ANDROID_API_LEVEL" --prefix="$BUILD_HOME/built/openssl" --openssldir="$BUILD_HOME/built/openssl"
RUN cd openssl-1.1.1d && make SHLIB_EXT='${SHLIB_VERSION_NUMBER}.so'
RUN cd openssl-1.1.1d && make install SHLIB_EXT='${SHLIB_VERSION_NUMBER}.so'

# This build container builds Python, rubicon-java, and any dependencies.
FROM toolchain as build_python
RUN apt-get update -qq && apt-get -qq install python3.7 pkg-config zip quilt

# Get libs & vars
COPY --from=build_openssl /opt/python-build/built/openssl /opt/python-build/built/openssl
COPY --from=build_bz2 /opt/python-build/built/libbz2 /opt/python-build/built/libbz2
COPY --from=build_xz /opt/python-build/built/xz /opt/python-build/built/xz
COPY --from=build_libffi /opt/python-build/built/libffi /opt/python-build/built/libffi
COPY --from=build_sqlite /opt/python-build/built/sqlite /opt/python-build/built/sqlite

ENV OPENSSL_INSTALL_DIR=/opt/python-build/built/openssl
ENV LIBBZ2_INSTALL_DIR="$BUILD_HOME/built/libbz2"
ENV LIBXZ_INSTALL_DIR="$BUILD_HOME/built/xz"
RUN mkdir -p "$JNI_LIBS" && cp -a "$OPENSSL_INSTALL_DIR"/lib/*.so "$LIBBZ2_INSTALL_DIR"/lib/*.so /opt/python-build/built/libffi/lib/*.so /opt/python-build/built/xz/lib/*.so /opt/python-build/built/sqlite/lib/*.so "$JNI_LIBS"
ENV PKG_CONFIG_PATH="/opt/python-build/built/libffi/lib/pkgconfig:/opt/python-build/built/xz/lib/pkgconfig"

# Download & patch Python
ADD downloads/Python-3.7.6.tar.xz .
# Modify ./configure so that, even though this is Linux, it does not append .1.0 to the .so file.
RUN sed -i -e 's,INSTSONAME="$LDLIBRARY".$SOVERSION,,' Python-3.7.6/configure
# Apply a C extensions linker hack; already fixed in Python 3.8+; see https://github.com/python/cpython/commit/254b309c801f82509597e3d7d4be56885ef94c11
RUN sed -i -e s,'libraries or \[\],\["python3.7m"] + libraries if libraries else \["python3.7m"\],' Python-3.7.6/Lib/distutils/extension.py
# Apply a hack to get the NDK library paths into the Python build. TODO(someday): Discuss with e.g. Kivy and see how to remove this.
RUN sed -i -e "s# dirs = \[\]# dirs = \[os.environ.get('SYSROOT_INCLUDE'), os.environ.get('SYSROOT_LIB')\]#" Python-3.7.6/setup.py
# Apply a hack to get the sqlite include path into setup.py. TODO(someday): Discuss with upstream Python if we can use pkg-config for sqlite.
RUN sed -i -E 's,sqlite_inc_paths = [[][]],sqlite_inc_paths = ["/opt/python-build/built/sqlite/include"],' Python-3.7.6/setup.py
# Apply a hack to make platform.py stop looking for a libc version.
RUN sed -i -e "s#Linux#DisabledLinuxCheck#" Python-3.7.6/Lib/platform.py

# Build Python, pre-configuring some values so it doesn't check if those exist.
ENV SYSROOT_LIB=${TOOLCHAIN}/sysroot/usr/lib/${TOOLCHAIN_TRIPLE}/${ANDROID_API_LEVEL}/ \
    SYSROOT_INCLUDE=${NDK}/sysroot/usr/include/
RUN cd Python-3.7.6 && LDFLAGS="$(pkg-config --libs-only-L libffi) $(pkg-config --libs-only-L liblzma) -L${LIBBZ2_INSTALL_DIR}/lib -L$OPENSSL_INSTALL_DIR/lib" \
    CFLAGS="${CFLAGS} -I${LIBBZ2_INSTALL_DIR}/include $(pkg-config --cflags-only-I libffi) $(pkg-config --cflags-only-I liblzma) " \
    ./configure --host "$TOOLCHAIN_TRIPLE" --build "$COMPILER_TRIPLE" --enable-shared \
    --enable-ipv6 ac_cv_file__dev_ptmx=yes \
    --with-openssl=$OPENSSL_INSTALL_DIR \
    ac_cv_file__dev_ptc=no --without-ensurepip ac_cv_little_endian_double=yes \
    --prefix="$PYTHON_INSTALL_DIR" \
    ac_cv_func_setuid=no ac_cv_func_seteuid=no ac_cv_func_setegid=no ac_cv_func_getresuid=no ac_cv_func_setresgid=no ac_cv_func_setgid=no ac_cv_func_sethostname=no ac_cv_func_setresuid=no ac_cv_func_setregid=no ac_cv_func_setreuid=no ac_cv_func_getresgid=no ac_cv_func_setregid=no ac_cv_func_clock_settime=no ac_cv_header_termios_h=no ac_cv_func_sendfile=no ac_cv_header_spawn_h=no ac_cv_func_posix_spawn=no \
    ac_cv_func_setlocale=no ac_cv_working_tzset=no ac_cv_member_struct_tm_tm_zone=no ac_cv_func_sched_setscheduler=no
# Override ./configure results to futher force Python not to use some libc calls that trigger blocked syscalls.
# TODO(someday): See if HAVE_INITGROUPS has another way to disable it.
RUN cd Python-3.7.6 && sed -i -E 's,#define (HAVE_CHROOT|HAVE_SETGROUPS|HAVE_INITGROUPS) 1,,' pyconfig.h
# Adjust timemodule.c to perform data validation for mktime(). The libc call is supposed to do its own
# validation, but on one Android 8.1 device, it doesn't. We leverage the existing AIX-related check in timemodule.c.
RUN cd Python-3.7.6 && sed -i -E 's,#ifdef _AIX,#if defined(_AIX) || defined(__ANDROID__),' Modules/timemodule.c
# Override posixmodule.c assumption that fork & exec exist & work.
RUN cd Python-3.7.6 && sed -i -E 's,#define.*(HAVE_EXECV|HAVE_FORK).*1,,' Modules/posixmodule.c
# Copy libbz2 into the SYSROOT_LIB. This is the IMHO the easiest way for setup.py to find it.
RUN cp "${LIBBZ2_INSTALL_DIR}/lib/libbz2.so" $SYSROOT_LIB
# Compile Python. We can still remove some tests from the test suite before `make install`.
RUN cd Python-3.7.6 && make

# Modify stdlib & test suite before `make install`.

# Apply a hack to ssl.py so it looks at the Android certificate store.
ADD 3.7.patches Python-3.7.6/patches
RUN cd Python-3.7.6 && quilt push
# Apply a hack to ctypes so that it loads libpython.so, even though this isn't Windows.
RUN sed -i -e 's,pythonapi = PyDLL(None),pythonapi = PyDLL("libpython3.7m.so"),' Python-3.7.6/Lib/ctypes/__init__.py
# Hack the test suite so that when it tries to remove files, if it can't remove them, the error passes silently.
# To see if ths is still an issue, run `test_bdb`.
RUN sed -i -e "s#NotADirectoryError#NotADirectoryError, OSError#" Python-3.7.6/Lib/test/support/__init__.py
# Ignore some tests
ADD 3.7.ignore_some_tests.py .
RUN python3.7 3.7.ignore_some_tests.py $(find Python-3.7.6/Lib/test -iname '*.py') $(find Python-3.7.6/Lib/distutils/tests -iname '*.py') $(find Python-3.7.6/Lib/unittest/test/ -iname '*.py') $(find Python-3.7.6/Lib/lib2to3/tests -iname '*.py')
# Skip test_multiprocessing in test_venv.py. Not sure why this fails yet.
RUN cd Python-3.7.6 && sed -i -e 's,def test_multiprocessing,def skip_test_multiprocessing,' Lib/test/test_venv.py
# Skip test_faulthandler & test_signal & test_threadsignals. Signal delivery on Android is not super reliable.
RUN cd Python-3.7.6 && rm Lib/test/test_faulthandler.py Lib/test/test_signal.py Lib/test/test_threadsignals.py
# In test_cmd_line.py:
# - test_empty_PYTHONPATH_issue16309() fails. I think it is because it assumes PYTHONHOME is set;
#   if we can fix our dependency on that variable for Python subprocesses, we'd be better off.
# - test_stdout_flush_at_shutdown() fails. The situation is that the test assumes you can't
#   close() a FD (stdout) that's already been closed; however, seemingly, on Android, you can.
RUN cd Python-3.7.6 && sed -i -e 's,def test_empty_PYTHONPATH_issue16309,def skip_test_empty_PYTHONPATH_issue16309,' Lib/test/test_cmd_line.py
RUN cd Python-3.7.6 && sed -i -e 's,def test_stdout_flush_at_shutdown,def skip_test_stdout_flush_at_shutdown,' Lib/test/test_cmd_line.py
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
ARG RUBICON_JAVA_VERSION=0.2020-02-27.0
ADD downloads/${RUBICON_JAVA_VERSION}.tar.gz .
RUN cd rubicon-java-${RUBICON_JAVA_VERSION} && \
    LDFLAGS='-landroid -llog' PYTHON_CONFIG=$PYTHON_INSTALL_DIR/bin/python3-config make
RUN mv rubicon-java-${RUBICON_JAVA_VERSION}/dist/librubicon.so $JNI_LIBS
RUN mkdir -p /opt/python-build/app/libs/ && mv rubicon-java-${RUBICON_JAVA_VERSION}/dist/rubicon.jar $APPROOT/app/libs/
RUN cd rubicon-java-${RUBICON_JAVA_VERSION} && zip -0 -q "$ASSETS_DIR"/rubicon.zip -r rubicon

RUN apt-get update -qq && apt-get -qq install rsync
