FROM ubuntu:18.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get -q -y install wget xz-utils unzip

# Install compiler
WORKDIR /opt/ndk
RUN wget -q https://dl.google.com/android/repository/android-ndk-r20b-linux-x86_64.zip && unzip -q android-ndk-r20b-linux-x86_64.zip && rm android-ndk-r20b-linux-x86_64.zip
ENV NDK /opt/ndk/android-ndk-r20b

# Do our Python build work here
WORKDIR /opt/python-build
RUN mkdir -p /opt/python-build/applibs

# Download our dependencies, but do not build them yet.

# Download libffi, dependency of ctypes
RUN wget -q https://github.com/libffi/libffi/releases/download/v3.3/libffi-3.3.tar.gz && tar xf libffi-3.3.tar.gz && rm libffi-3.3.tar.gz

# Download & patch Python
RUN apt-get update && apt-get -y install python3.7 pkg-config git zip
RUN wget -q https://www.python.org/ftp/python/3.7.6/Python-3.7.6.tar.xz && tar xf Python-3.7.6.tar.xz && rm Python-3.7.6.tar.xz
# Apply a C extensions linker hack; already fixed in Python 3.8+; see https://github.com/python/cpython/commit/254b309c801f82509597e3d7d4be56885ef94c11
RUN sed -i -e s,'libraries or \[\],\["python3.7m"] + libraries if libraries else \["python3.7m"\],' Python-3.7.6/Lib/distutils/extension.py
# Apply a hack to get the NDK library paths into the Python build. TODO(someday): Discuss with e.g. Kivy and see how to remove this.
RUN sed -i -e "s# dirs = \[\]# dirs = \[os.environ.get('NDK') + \"/sysroot/usr/include\", os.environ.get('TOOLCHAIN') + \"/sysroot/usr/lib/\" + os.environ.get('TARGET') + '/' + os.environ.get('ANDROID_SDK_VERSION')\]#" Python-3.7.6/setup.py
# Apply a hack make platform.py stop looking for a libc version.
RUN sed -i -e "s#Linux#DisabledLinuxCheck#" Python-3.7.6/Lib/platform.py
# Ignore some tests
ADD 3.7.ignore_some_tests.py .
RUN python3.7 3.7.ignore_some_tests.py $(find Python-3.7.6/Lib/test -iname '*.py')

# Build Python
COPY 3.7.phase_2.sh .
RUN bash 3.7.phase_2.sh x86_64-linux-android
