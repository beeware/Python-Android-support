Python Android Support
======================

This is a meta-package for building a version of CPython that can be embedded
into an Android project.

It works by downloading, patching, and building CPython and selected pre-
requisites, and packaging them as linkable dynamic libraries that can be
included in an Android Gradle project.

The binaries support armeabi-v7a, arm64-v8a, x86 and x86_64. This should enable
the code to run on most modern Android devices.

The master branch of this repository has no content; there is an
independent branch for each supported version of Python. The following
Python versions are supported:

.. * `Python 3.6 <https://github.com/beeware/Python-Android-support/tree/3.6>`__
* `Python 3.7 <https://github.com/beeware/Python-Android-support/tree/3.7>`__
.. * `Python 3.8 <https://github.com/beeware/Python-Android-support/tree/3.8>`__
.. * `Python 3.9 <https://github.com/beeware/Python-Android-support/tree/3.9>`__

Suggestions for changes should be made against the `dev branch
<https://github.com/beeware/Python-Android-support/tree/dev>`__; these
will then be backported into the supported Python releases. The dev branch will
track the most recent supported version of Python (currently, Python 3.7).

See the individual branches for usage instructions.
