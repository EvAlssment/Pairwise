"""Download an exact official LiveKit bundle; never resolve a moving 'latest'."""
import argparse
import hashlib
import pathlib
import tarfile
import urllib.request
import zipfile

VERSION = "1.13.1"
BUNDLES = {
    "windows-x64": ("zip", "6696ee87c78b958bdbf70e5eb39bf85e1c7528ca2a707e6c13b042c8e4360b9d"),
    "macos-arm64": ("tar.gz", "37aec7b5583826a91316edacb72adad5cbf5d83d5644f331b40b2c44a25934aa"),
}


def fetch(platform, destination):
    extension, expected = BUNDLES[platform]
    name = f"livekit-sdk-{platform}-{VERSION}.{extension}"
    destination.mkdir(parents=True, exist_ok=True)
    archive = destination / name
    if not archive.exists():
        url = f"https://github.com/livekit/client-sdk-cpp/releases/download/v{VERSION}/{name}"
        with urllib.request.urlopen(url, timeout=60) as source, archive.open("wb") as output:
            while chunk := source.read(1024 * 1024):
                output.write(chunk)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
        raise RuntimeError("LiveKit bundle checksum mismatch")
    # Both archive formats are validated before extracting, including links.
    if extension == "zip":
        with zipfile.ZipFile(archive) as bundle:
            for item in bundle.infolist():
                path = (destination / item.filename).resolve()
                if not path.is_relative_to(destination.resolve()):
                    raise RuntimeError("Invalid archive member")
            bundle.extractall(destination)
    else:
        with tarfile.open(archive) as bundle:
            bundle.extractall(destination, filter="data")
    print(destination / f"livekit-sdk-{platform}-{VERSION}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("platform", choices=BUNDLES)
    parser.add_argument("destination", type=pathlib.Path)
    args = parser.parse_args()
    fetch(args.platform, args.destination)
