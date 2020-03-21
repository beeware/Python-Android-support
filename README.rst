Python Android Support
======================

**This repository branch builds a packaged version of Python 3.7.6**.
Other Python versions are available by cloning other branches of the main
repository.

This is a meta-package for building a version of CPython that can be embedded
into an Android project.

It works by downloading, patching, and building CPython and selected pre-
requisites, and packaging them as linkable dynamic libraries.

Quickstart
----------

The easiest way to use this support package is to use `briefcase
<https://github.com/beeware/briefcase>`__. Briefcase uses a pre-compiled
version of the support package to build complete Android applications. See
`Briefcase's documentation <https://briefcase.readthedocs.io>`__ for more
details.

Pre-built versions of the frameworks `can be downloaded`_ and added to your
project. See `this documentation <./USAGE.md>`__ for more details on how to
build an Android project using this support package.

Alternatively, to build the frameworks on your own, download/clone this
repository, and then in the root directory, and run `./3.7.sh` to build
everything. You will need Docker installed; all other requirements will
be downloaded as part of the installation script.

This should:

1. Download the original source packages
2. Patch them as required for compatibility with the selected OS
3. Build the packages.

The build products will be in the `build` directory; the compiled artefacts
will be in the `dist` directory.

You can then follow `these same instructions <./USAGE.md>`__ for building
an Android application.

.. _can be downloaded: https://briefcase-support.org/python?platform=android&version=3.7
