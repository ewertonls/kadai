"""Print the version to embed in Kadai for a v-prefixed SemVer tag."""

import re
import sys


NUMBER = r"(?:0|[1-9][0-9]*)"
# A numeric prerelease identifier follows NUMBER. Others contain a letter or hyphen.
PRERELEASE_ID = rf"(?:{NUMBER}|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
BUILD_ID = r"[0-9A-Za-z-]+"
TAG = re.compile(
    rf"v{NUMBER}\.{NUMBER}\.{NUMBER}"
    rf"(?:-{PRERELEASE_ID}(?:\.{PRERELEASE_ID})*)?"
    rf"(?:\+{BUILD_ID}(?:\.{BUILD_ID})*)?"
)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: release_version.py TAG")
    tag = sys.argv[1]
    if not TAG.fullmatch(tag):
        sys.exit(f"invalid release tag {tag!r}: expected a v-prefixed SemVer such as v0.1.0-rc.1")
    print(tag[1:])
