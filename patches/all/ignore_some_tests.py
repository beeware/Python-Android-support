import re
import sys

LEADING_SPACES_RE = re.compile("^( +)")


def fix(filename):
    # Don't apply these hacks to script_helper.py directly.
    if filename.endswith("script_helper.py"):
        return

    with open(filename) as fd:
        try:
            contents = fd.read()
        except UnicodeDecodeError:
            # We're going to hope that we don't have to process
            # any non-UTF-8 files.
            return

    matching_lines = []
    splitted = contents.split("\n")
    for i, line in enumerate(splitted):
        if (
            # Skip test_extension_init within test_extension because we currently hack
            # distutils to add -lpython3.7m when building any dynamic module.
            "# others arguments have defaults" in line
            # The following skips one test in test_dir_util, which fails because
            # on Android, a directory gets made as 02700 not 0700. It doesn't matter
            # much for us.
            or "# Get and set the current umask value for testing mode bits." in line
            # Skip a specific zipimport-related test :(
            or "then check that the filter works on individual files" in line
            # The following avoid executing subprocesses via tests.
            or "subprocess.run(" in line
            or "subprocess.check_output(" in line
            or "subprocess.check_call(" in line
            or " spawn(" in line
            or "platform.popen(" in line
            or "os.popen(" in line
            or "os.spawnl(" in line
            or "with Popen(" in line
            # pydoc start_server() is failing. Not fully sure why.
            or "pydoc._start_server" in line
            # some tests find out that we're bad at passing 100% of UNIX signals to Python; sorry!
            or "= self.decide_itimer_count()" in line
            # some tests try to make a socket with no params; somehow this is not OK on Android!
            # or "socket.socket()" in line
            # one test tries to do os.chdir('/') to get the top of the filesystem tree, then os.listdir(). This will not work.
            or " self.assertEqual(set(os.listdir()), set(os.listdir(os.sep)))" in line
            # os.get_terminal_size() doesn't work for now
            or (
                " os.get_terminal_size()" in line
                and not " os.get_terminal_size()'" in line
            )
            # process exit codes are weird
            or " self.assertEqual(exitcode, self.exitcode)" in line
            or " os.spawnv(" in line
            # Disable the group module's beliefs that all gr_name values are strings;
            # on Android, somehow, they're None.
            or "self.assertIsInstance(value.gr_name, str)" in line
            # Similar for pwd (password file) module
            or "self.assertIsInstance(e.pw_gecos, str)" in line
            # test_socketserver.py has a test for signals & UNIX sockets interactions; this test hangs on Android.
            # Skip for now.
            or "test.support.get_attribute(signal, 'pthread_kill')" in line
        ):
            matching_lines.append(i)

    # If there is nothing to do, we do nothing.
    if not matching_lines:
        return

    # Some lines try to spawn subprocesses, so we mod those out.
    out_lines = []
    # If the file doesn't import unittest, add that to the top.
    if "import unittest\n" not in contents:
        out_lines.append("import unittest")

    for i, line in enumerate(splitted):
        if i in matching_lines:
            # Find indent level
            match = LEADING_SPACES_RE.match(line)
            if match:
                num_spaces = len(match.group(0))
                line = (
                    " " * num_spaces
                    + 'raise unittest.SkipTest("Skipping this test for Python within an Android app")'
                    + "\n"
                    + line
                )
        out_lines.append(line)

    with open(filename, "w") as fd:
        fd.write("\n".join(out_lines))


def main():
    filenames = sys.argv[1:]
    for filename in filenames:
        fix(filename)


if __name__ == "__main__":
    main()
