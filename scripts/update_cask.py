"""Generate a cask from the exact published archive (never from a rebuild)."""
import argparse
import hashlib
import pathlib
import re

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("version")
parser.add_argument("archive", type=pathlib.Path)
parser.add_argument("cask", type=pathlib.Path)
parser.add_argument("--only-if-newer", action="store_true")
args = parser.parse_args()
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", args.version):
    raise SystemExit("Invalid release version")
text = args.cask.read_text()
current = re.search(r'version "([0-9.]+)"', text)
if not current or not re.search(r'sha256 "[^"]+"', text):
    raise SystemExit("Cask does not contain expected version and checksum fields")
if args.only_if_newer and tuple(map(int, args.version.split("."))) < tuple(map(int, current[1].split("."))):
    print("Keeping the cask for the newer release")
    raise SystemExit(0)
digest = hashlib.sha256()
with args.archive.open("rb") as archive:
    for chunk in iter(lambda: archive.read(1024 * 1024), b""):
        digest.update(chunk)
text = re.sub(r'version "[^"]+"', f'version "{args.version}"', text, count=1)
text = re.sub(r'sha256 "[^"]+"', f'sha256 "{digest.hexdigest()}"', text, count=1)
args.cask.write_text(text)
