import hashlib
from pathlib import Path
import subprocess
import tarfile
from tempfile import TemporaryDirectory

def sha256(stream):
    digest = hashlib.sha256()
    for block in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(block)
    return digest.hexdigest()

def published_binary(series, name, digest, member):
    url = f"https://github.com/shivammathur/php-darwin/releases/download/php-{series}/{name}"
    with TemporaryDirectory() as directory:
        archive = Path(directory) / name
        subprocess.run(["curl", "-qfsSL", "--retry", "3", "--connect-timeout", "10",
                        "--max-time", "240", "--output", str(archive), url], check=True)
        with archive.open("rb") as f:
            actual = sha256(f)
        if actual != digest:
            raise ValueError(f"Published archive SHA-256 mismatch: {actual} != {digest}")
        with subprocess.Popen(["zstd", "-qdc", str(archive)], stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL) as unpack:
            try:
                with tarfile.open(fileobj=unpack.stdout, mode="r|", bufsize=1024 * 1024) as tar:
                    for entry in tar:
                        if entry.name.removeprefix("./") == member and entry.isfile():
                            return sha256(tar.extractfile(entry))
                raise FileNotFoundError(member)
            finally:
                unpack.stdout.close()
