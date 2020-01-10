import re
import sys

LEADING_SPACES_RE = re.compile("^( +)")


def fix(filename):
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
            # The following skips one test (test_extension_init within text_extension)
            # because we currently hack distutils to add -lpython3.7m when building any
            # dynamic module.
            "# others arguments have defaults" in line
            # The following skips one test in test_dir_util, which fails because
            # on Android, a directory gets made as 02700 not 0700. It doesn't matter
            # much for us.
            or "# Get and set the current umask value for testing mode bits." in line
            # The following avoid executing subprocesses via tests.
            or "subprocess.Popen(" in line
            or "subprocess.run(" in line
            or "subprocess.check_output(" in line
            or "spawn(" in line
            or "Platform.popen(" in line
            or "os.popen(" in line
            or "os.spawnl(" in line
            or "with Popen(" in line
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
                    + 'raise unittest.SkipTest("Skipping because subprocess not available")'
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
