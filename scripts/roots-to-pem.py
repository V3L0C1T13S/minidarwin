#!/usr/bin/env python3
"""Render security_certificates' trusted roots as one PEM bundle (cert.pem).

Usage: roots-to-pem.py <security_certificates source> <tag> > cert.pem

Every DER file in certificates/roots, sorted by name, except the roots that
certificates/constraints.json's "system" section restricts to Apple policy
OIDs. The Security framework enforces those constraints; an OpenSSL CA file
cannot carry them, so listing such a root would trust it for everything.

Each file is named by the SHA-256 of its DER; that is checked, and the name
printed above each certificate comes from hash_to_human_name.json.
"""
import base64
import hashlib
import json
import os
import sys


def main():
    src, tag = sys.argv[1:3]
    certs = os.path.join(src, "certificates")
    roots_dir = os.path.join(certs, "roots")

    with open(os.path.join(certs, "constraints.json")) as f:
        constrained = set(json.load(f)["system"])
    with open(os.path.join(certs, "hash_to_human_name.json")) as f:
        names = json.load(f)

    roots = sorted(os.listdir(roots_dir))
    hashes = set()
    for name in roots:
        if not name.endswith(".cer"):
            sys.exit(f"roots-to-pem: unexpected file roots/{name}")
        hashes.add(name[:-4])
    # A constraint on a root that is no longer there means the layout moved.
    stale = constrained - hashes
    if stale:
        sys.exit(f"roots-to-pem: constrained roots not in roots/: {sorted(stale)}")

    out = sys.stdout
    out.write(f"# Trusted roots of Apple's {tag} (certificates/roots),\n")
    out.write(f"# less the {len(constrained)} that constraints.json restricts to Apple policies.\n")
    n = 0
    for name in roots:
        digest = name[:-4]
        if digest in constrained:
            continue
        with open(os.path.join(roots_dir, name), "rb") as f:
            der = f.read()
        if hashlib.sha256(der).hexdigest().upper() != digest:
            sys.exit(f"roots-to-pem: roots/{name} does not match its name")
        if digest not in names:
            sys.exit(f"roots-to-pem: roots/{name} has no hash_to_human_name.json entry")
        b64 = base64.b64encode(der).decode("ascii")
        out.write(f"\n# {names[digest]}\n# SHA-256 {digest}\n")
        out.write("-----BEGIN CERTIFICATE-----\n")
        for i in range(0, len(b64), 64):
            out.write(b64[i:i + 64] + "\n")
        out.write("-----END CERTIFICATE-----\n")
        n += 1
    print(f"roots-to-pem: {n} roots, {len(constrained)} left out", file=sys.stderr)


if __name__ == "__main__":
    main()
