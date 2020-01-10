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
        if "subprocess.Popen(" in line:
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
