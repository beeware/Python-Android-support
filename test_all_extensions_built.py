import sys
import zipfile


def main():
    support_lib_filename = sys.argv[1]
    support_lib = zipfile.ZipFile(support_lib_filename)
    # Find the first pythonhome.*.zip and check for expected C extensions.
    try:
        pythonhome_filename = [
            filename
            for filename in support_lib.namelist()
            if "pythonhome." in filename and filename.endswith(".zip")
        ][0]
    except IndexError:
        print(f"No pythonhome.*.zip in {support_lib_filename}. Aborting.")
        sys.exit(1)
    pythonhome = zipfile.ZipFile(support_lib.open(pythonhome_filename))
    c_extensions = {
        "_lzma.": False,
        "_sqlite3.": False,
        "_ctypes.": False,
        "_ssl.": False,
        "_bz2.": False,
    }
    for filename in pythonhome.namelist():
        if "lib/python" in filename and filename.endswith(".so"):
            for c_extension in c_extensions:
                if c_extensions[c_extension]:
                    continue
                if c_extension in filename:
                    c_extensions[c_extension] = filename
    for c_extension in c_extensions:
        found_filename = c_extensions[c_extension]
        is_present_string = "PASS" if c_extensions[c_extension] else "FAIL"
        print(f"{is_present_string} - {c_extension} - {found_filename} (within {pythonhome_filename})")
    if not all(c_extensions.values()):
        print("Missing at least expected one C extension")
        sys.exit(1)


if __name__ == "__main__":
    main()
