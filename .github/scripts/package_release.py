"""Package the native Kadai build and verify it from a fresh extraction."""

import filecmp
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

from release_version import TAG


def package_release(version, output_dir):
    if not TAG.fullmatch("v" + version):
        sys.exit(f"invalid package version: {version!r}")
    system = platform.system().lower()
    machine = platform.machine().lower()
    arch = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64"}[machine]
    binary = "kadai.exe" if system == "windows" else "kadai"
    inspector = {
        "linux": ["readelf", "-dW"],
        "darwin": ["otool", "-L"],
        "windows": ["llvm-readobj", "--needed-libs"],
    }[system]
    files = {
        binary: Path(binary),
        "LICENSE": Path("LICENSE"),
        "licenses/LibYAML.txt": Path("third_party/odin-yaml/lib/LICENSE.libyaml"),
        "licenses/odin-yaml.txt": Path("third_party/odin-yaml/LICENSE"),
    }
    with tempfile.TemporaryDirectory() as tmp:
        stage = Path(tmp) / "stage"
        for name, source in files.items():
            dest = stage / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, dest)

        base = Path(tmp) / f"kadai-{version}-{system}-{arch}"
        archive = Path(shutil.make_archive(str(base), "zip" if system == "windows" else "gztar", stage))
        extracted = Path(tmp) / "extracted"
        shutil.unpack_archive(archive, extracted)
        for name, source in files.items():
            if not filecmp.cmp(source, extracted / name, shallow=False):
                sys.exit(f"packaged file differs from build input: {name}")
        actual = subprocess.check_output([extracted / binary, "--version"], cwd=extracted, text=True)
        if actual != f"kadai {version}\n":
            sys.exit(f"expected kadai {version}, got {actual!r}")
        dependencies = subprocess.check_output([*inspector, binary], cwd=extracted, text=True)
        print(dependencies)
        if "yaml" in dependencies.lower():
            sys.exit("packaged executable depends on shared LibYAML")

        output_dir.mkdir(parents=True, exist_ok=True)
        shutil.move(archive, output_dir / archive.name)
        print(f"Verified {archive.name} ({actual.strip()})")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: package_release.py VERSION OUTPUT_DIR")
    package_release(sys.argv[1], Path(sys.argv[2]))
