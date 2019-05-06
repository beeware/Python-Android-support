Python Android Support
======================

This is a meta-package for building a version of CPython that can be embedded
into an Android project.

It works by downloading, patching, and building CPython and selected pre-
requisites, and packaging them as linkable dynamic libraries.

The binaries support armeabi-v7a, arm64-v8a, x86 and x86_64. This should enable
the code to run on most modern Android devices.

The master branch of this repository has no content; there is an
independent branch for each supported version of Python. The following
Python versions are supported:

* `Python 3.6 <https://github.com/pybee/Python-Android-support/tree/3.6>`__
.. * `Python 3.7 <https://github.com/pybee/Python-Android-support/tree/3.7>`__
