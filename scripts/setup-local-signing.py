#!/usr/bin/env python3
"""Create one private, reusable code-signing identity for this Mac's dev builds.

This does not trust a root certificate, change TCC, or grant Accessibility access.
The private key lives in a dedicated keychain, outside the repository and app.
"""
import os
from pathlib import Path
import secrets
import subprocess
import tempfile


def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, **kwargs)


def main():
    os.umask(0o077)
    directory = Path(os.environ.get("CLIPSHELF_LOCAL_SIGNING_DIR", str(
        Path.home() / "Library/Application Support/ClipShelf Development Signing")))
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    if directory.is_symlink():
        raise RuntimeError("The signing directory must not be a symlink")
    identity = directory / "identity.txt"
    keychain = directory / "development.keychain-db"
    password_file = directory / "keychain-password"
    if identity.exists():
        if not keychain.is_file() or not password_file.is_file():
            raise RuntimeError("Incomplete signing identity; preserve the existing files for recovery")
        certificate = run("/usr/bin/security", "find-certificate", "-c", "ClipShelf Local Development", "-p", str(keychain)).stdout
        (directory / "certificate.pem").write_bytes(certificate)
        print("Reusing local signing identity:", identity.read_text().strip())
        print("Signing still requires explicit code-signing trust; this script does not change trust settings.")
        return
    if keychain.exists() or password_file.exists():
        raise RuntimeError("Partial setup found; refusing to replace signing credentials")
    password = secrets.token_urlsafe(36)
    password_file.write_text(password)
    run("/usr/bin/security", "create-keychain", "-p", password, str(keychain))
    run("/usr/bin/security", "unlock-keychain", "-p", password, str(keychain))
    with tempfile.TemporaryDirectory(prefix="certificate-", dir=directory) as temporary:
        work = Path(temporary)
        config = work / "certificate.cnf"
        config.write_text("""[req]
distinguished_name = subject
x509_extensions = signing
prompt = no
[subject]
CN = ClipShelf Local Development
[signing]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
""")
        key, cert, bundle = (work / name for name in ("private.pem", "certificate.pem", "identity.p12"))
        run("/usr/bin/openssl", "req", "-new", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-days", "3650", "-config", str(config), "-keyout", str(key), "-out", str(cert))
        env = dict(os.environ, CLIPSHELF_P12_PASSWORD=password)
        run("/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(key), "-in", str(cert),
            "-out", str(bundle), "-passout", "env:CLIPSHELF_P12_PASSWORD", env=env)
        run("/usr/bin/security", "import", str(bundle), "-k", str(keychain), "-P", password,
            "-T", "/usr/bin/codesign")
        # Only Apple's signing tool may use this private key without an ACL prompt.
        run("/usr/bin/security", "set-key-partition-list", "-S", "apple-tool:", "-s",
            "-k", password, str(keychain))
        fingerprint = run("/usr/bin/openssl", "x509", "-in", str(cert), "-noout", "-fingerprint", "-sha1").stdout.decode().strip().split("=", 1)[1].replace(":", "")
        if len(fingerprint) != 40 or any(c not in "0123456789ABCDEF" for c in fingerprint):
            raise RuntimeError("Invalid certificate fingerprint")
        identity.write_text(fingerprint + "\n")
        (directory / "certificate.pem").write_bytes(cert.read_bytes())
    print("Created local signing identity:", fingerprint)
    print("No system trust or Accessibility settings were changed.")
    print("Signing requires explicit code-signing trust before this identity can be used.")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        # Never print argv: keychain and PKCS12 passwords are command arguments.
        raise SystemExit(f"Local signing setup failed (exit {error.returncode}); preserve the signing directory.")
