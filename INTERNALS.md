# Maintaining these scripts

The `3.7.sh` script downloads some source code, then passes control to `docker`
which runs `3.7.Dockerfile`. This configures dependencies, patches Python, and
does the build.

The shell script does nearly all of the downloading up-front. This allows the
Docker-based build process to make the best use possible of the Docker cache.
The Dockerfile does include some `apt-get` calls, which I consider an
acceptable compromise of this design goal.

The Dockerfile patches the source code using `sed`, a custom Python script
called `3.7.ignore_some_tests.py`, and patches that we apply using `quilt`.

It uses `sed` when making changes that I do not intend to send upstream. It is
easy to use `sed` to make one-line changes to various files, and these changes
are resilient to the lines moving around slightly.

The `3.7.ignore_some_tests.py` makes a lot of changes to the Python test suite,
focusing on removing tests that do not make sense within the context of an
Android app. Most of these relate to disabling the use of Python subprocesses
to run parts of the test suite. Launching subprocesses works properly within an
Android app on some API versions. However, the `libpython` that we build
requires setting the `PYTHONHOME` environment variable at the moment, so it was
easier to disable these tests than to ensure that variable is threaded through
appropriately. Another difficulty is that in more recent versions of Android,
launching subprocesses [requires additional work to comply with new sandboxing
restrictions.](https://www.reddit.com/r/androiddev/comments/b2inbu/psa_android_q_blocks_executing_binaries_in_your/)
Because there are a lot of tests that needed to be changed, and at the moment I
don't plan to upstream this, I consider this similar to the use of `sed`, but
more powerful.

It also uses a patch which is added to the Python source tree using `quilt`.
This is a patch which allows Python to use the Android system certificates to
validate TLS/SSL connections. It will probably make sense to upstream this
after some revision; however, it will not necessarily land in the Python 3.7
branch even when upstreamed. To learn more about using quilt, read [this
documentation about
quilt.](https://www.yoctoproject.org/docs/1.8/dev-manual/dev-manual.html#using-a-quilt-workflow)
If we need more patches to Python that are substantial and may be upstreamed,
relying more on `quilt` might be wise.

If you attempt to run the full Python standard library test suite, it should
all pass. Note that the Docker-based build also manually removes some parts of
the Python standard library test suite to accommodate this goal! You can find
an app to run the Python standard library test suite in
[Python-Android-sample-apps](https://github.com/paulproteus/Python-Android-sample-apps).
