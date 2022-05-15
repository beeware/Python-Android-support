Python Android Support
======================

This is a meta-package for building a version of CPython that can be embedded
into an Android project. It supports Python versions 3.6, 3.7, 3.8, and 3.9.

It works by downloading, patching, and building CPython and selected pre-
requisites, packaging them as linkable dynamic libraries, and packaging
that into a ZIP file. It builds binaries for all four major Android ABIs.

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
repository, and then in the root directory, and run ``./main.sh`` to build
everything. You will need Docker installed; all other requirements will
be downloaded as part of the installation script.

This should:

1. Download the original source packages
2. Patch them as required for compatibility with the selected OS
3. Build the packages.

The build products will be in the ``build`` directory; the compiled artifacts
will be in the ``dist`` directory.

You can then follow `these same instructions <./USAGE.md>`__ for building
an Android application.

Testing
-------

When you do a local build, you can use the ``support_package = ...`` configuration
option in a briefcase app's ``pyproject.toml`` to point the app at your local
support library.

You can run ``python3 test_all_extensions_built.py dist/Python-*-Android-support.zip``
to quickly validate that the expected compiled extension modules are available for a
given build.

To run the CPython test suite within an app context, you can add this code to a
briefcase app::

    import os, sys
    sys.executable = sys.prefix + "/bin/" + sorted([x for x in os.listdir(sys.prefix + "/bin/") if x.startswith("python3.")])[0]
    os.chmod(sys.executable, 0o755)
    from test.libregrtest import main
    result = None
    try:
        result = main([], use_resources=['network'])
    except SystemExit as e:
        # Do not let SystemExit bubble up further; if the app exits with a nonzero
        # status code, Android restarts it, which is rather annoying. :)
        print('Would exit with statuscode', e.code)
    else:
        print("Tests finished with result", result)

Note that you must modify the ``pythonhome`` excludes list for this to work properly,
which will make the support package larger.

.. _can be downloaded: https://briefcase-support.org/python?platform=android&version=3.7
