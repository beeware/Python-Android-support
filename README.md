This contains scripts for building Python on Android. It allows you
to generate a Python support ZIP file, which is a file you an unpack
over an Android app to get Python support in that Android app.

Table of contents:

- Generating a Python support ZIP file

- Maintaining these scripts

- Creating a sample app for Android

## Generating a Python support ZIP file

If you have `docker` installed, you can `git clone` this repository
and run `./3.7.sh`. This will run for about 45 minutes, then create a
Python support ZIP file at `output/3.7.zip`.

You can run e.g. `3.7.sh x86` to rebuild the Python support code for
one or more Android ABIs. This allows faster iteration.

## Maintaining these scripts

The `3.7.sh` script downloads some source code, then passes control to
`docker` which runs `3.7.Dockerfile`. This configures dependencies,
patches Python, and does the build.

The shell script does nearly all of the downloading up-front. This
allows the Docker-based build process to make the best use possible of
the Docker cache. The Dockerfile does include some `apt-get` calls,
which I consider an acceptable compromise of this design goal.

The Dockerfile patches the source code using `sed`, a custom Python
script called `3.7.ignore_some_tests.py`, and patches that we apply
using `quilt`.

It uses `sed` when making changes that I do not intend to send
upstream. It is easy to use `sed` to make one-line changes to
various files, and these changes are resilient to the lines
moving around slightly.

The `3.7.ignore_some_tests.py` makes a lot of changes to the Python
test suite, focusing on removing tests that do not make sense within
the context of an Android app. Most of these relate to disabling the
use of Python subprocesses to run parts of the test suite. Launching
subprocesses works properly within an Android app on some API
versions. However, the `libpython` that we build requires setting the
`PYTHONHOME` environment variable at the moment, so it was easier to
disable these tests than to ensure that variable is threaded through
appropriately. Another difficulty is that in more recent versions of
Android, launching subprocesses [requires additional work to comply
with new sandboxing
restrictions.](https://www.reddit.com/r/androiddev/comments/b2inbu/psa_android_q_blocks_executing_binaries_in_your/)
Because there are a lot of tests that needed to be changed, and at the
moment I don't plan to upstream this, I consider this similar to the
use of `sed`, but more powerful.

It also uses a patch which is added to the Python source tree using
`quilt`. This is a patch which allows Python to use the Android system
certificates to validate TLS/SSL connections. It will probably make
sense to upstream this after some revision; however, it will not
necessarily land in the Python 3.7 branch even when upstreamed. To
learn more about using quilt, read [this documentation about
quilt.](https://www.yoctoproject.org/docs/1.8/dev-manual/dev-manual.html#using-a-quilt-workflow) If we need more patches to Python that are substantial and
may be upstreamed, relying more on `quilt` might be wise.

If you attempt to run the full Python standard library test suite, it
should all pass. Note that the Docker-based build also manually
removes some parts of the Python standard library test suite to
accommodate this goal! You can find an app to run the Python standard
library test suite in
[Python-Android-sample-apps](https://github.com/paulproteus/Python-Android-sample-apps).

## Creating a sample app for Android

In these steps, you will:

- Download the Android SDK.
- Download/configure an appropriate version of Java.
- Configure an Android emulator.
- Generate a Python-based Android app using cookiecutter.
- Download a Python Android support ZIP file, and add that to your app. (You can build it yourself if you prefer.)
- Run the app on the Android emulator.

This will require approximately 5GB of disk space and downloads. It
will require about 30 minutes of time. I have tested these instructions
on macOS and Ubuntu 18.04.

### Downloading the Android SDK

On macOS, run the following commands.

```
$ mkdir -p ~/android/sdk && cd ~/android/sdk
$ curl -O https://dl.google.com/android/repository/sdk-tools-darwin-4333796.zip
$ unzip sdk*zip
```

If you’re on Linux, you’d need to use a different URL,
e.g. https://dl.google.com/android/repository/sdk-tools-linux-4333796.zip
.

These URLs have existed since approximately 2017, and they have a
built-in autoupdater, so I expect them to keep working for quite a few
years longer.

### Download/configure an appropriate version of Java

Ensure you have Java 8. Look at the output of this command.

```
$ java -version
```

If macOS shows a pop-up explaining that Java is not installed,
offering "More Info" and "OK," click "OK."

On macOS, if you don’t have Java, or the version is not Java 8, run
these commands:

$ brew tap adoptopenjdk/openjdk
$ brew cask install adoptopenjdk8

See also: https://stackoverflow.com/a/55775566

### Configure the Android SDK

```
$ export ANDROID_SDK_ROOT="${PWD}"
$ PATH="$PATH:${ANDROID_SDK_ROOT}/tools/bin:${ANDROID_SDK_ROOT}/emulator:${ANDROID_SDK_ROOT}/platform-tools"
$ mkdir -p ~/.android
$ touch ~/.android/repositories.cfg
$ sdkmanager --update
$ sdkmanager --licenses
$ sdkmanager 'platforms;android-28' 'system-images;android-28;default;x86' 'emulator' 'platform-tools'
```

### Configure an Android emulator

Open a **new** terminal window/tab and run the following.

```
$ export ANDROID_SDK_ROOT="${HOME}/android/sdk"
$ PATH="$PATH:${ANDROID_SDK_ROOT}/tools/bin:${ANDROID_SDK_ROOT}/emulator:${ANDROID_SDK_ROOT}/platform-tools"
$ avdmanager --verbose create avd --name robotFriend --abi x86 --package 'system-images;android-28;default;x86' --device pixel
$ echo 'disk.dataPartition.size=4096M' >> $HOME/.android/avd/robotFriend.avd/config.ini
$ echo 'hw.keyboard=yes' >> $HOME/.android/avd/robotFriend.avd/config.ini
$ emulator @robotFriend
```

The emulator command will open an Android emulator, and will block your terminal window.

### Generate a Python-based Android app with cookiecutter

In your original terminal, run the following commands.

```
$ python3 -m pip install --user cookiecutter
$ mkdir -p ~/projects/beeware-sample-app
$ cd ~/projects/beeware-sample-app
$ python3 -m cookiecutter https://github.com/paulproteus/cookiecutter-beeware-android
```

Now, in a web browser, visit this URL:

https://drive.google.com/uc?export=download&id=1Bsr_3VMkEez5VWHq2tjjwl8xwHpffIcb

And download 3.7.zip.

Back in a terminal, run:


```
$ cd MyApp # or whatever you said for project_name above
$ unzip ~/Downloads/3.7.zip
```

Finally, we need to create some sample Python code.

I'm assuming you called your app `my_app` in the earlier sections.
Create a file called `app/src/main/assets/python/my_app/__init__.py`
with the following content:

```python
from rubicon.java import JavaClass, JavaInterface

IPythonApp = JavaInterface('org/beeware/android/IPythonApp')

class Application(IPythonApp):
    def onCreate(self):
        print('called Python onCreate()')

    def onStart(self):
        print('called Python onStart()')

    def onResume(self):
        print('called Python onResume()')
```

Create another file called `app/src/main/assets/my_app/__main__.py`
with the following content.

```python
from . import Application
from rubicon.java import JavaClass

activity_class = JavaClass('org/beeware/android/MainActivity')
app = Application()
activity_class.setPythonApp(app)
print('Python app launched & stored in Android Activity class')
```

### Run the app on the Android emulator

Run this in a terminal.

```
$ ./gradlew installDebug
```

After about 3 minutes of waiting, the command should successfully
exit. Note that this command will be faster any future times you run
it.

In the emulator, find the circle icon at the bottom, next to the back
icon. Drag the circle icon up, and look for MyApp. Click it.

After about 10 seconds, you will see your app name visible. This means
the app is launched.

Now, let’s look through the Android log to find evidence that our app
launched. We’re looking for “called Python onCreate()” in the
following output.

```
$ adb logcat -d | grep -i python
```

TA-DA! It works.

You may notice that the Android image looks somewhat unstyled. This is
the fastest to download Android image; it contains all of fully open
source Android APIs, but it lacks Google’s additional APIs. I’ve
tested it, and the app displays properly this way. Based on my
research I expect that all APIs we will wrap will continue to work
properly with this Android image.
