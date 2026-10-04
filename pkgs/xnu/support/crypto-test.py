#!/usr/bin/env python3
"""Independent SHA/HMAC comparisons and published NIST DRBG known answers."""
import hashlib
import hmac
import json
from pathlib import Path
import subprocess
import sys

def run(*args):
    return subprocess.check_output(["./crypto-test", *args], text=True).strip()

for algo in ("sha1", "sha256", "sha384", "sha512"):
    for size in (0, 3, 55, 56, 63, 64, 65, 111, 112, 127, 128, 129, 1000):
        data = bytes(i % 251 for i in range(size))
        for mode in ("digest", "api-digest"):
            assert run(mode, algo, data.hex()) == hashlib.new(algo, data).hexdigest()
        for kn in (0, 3, 64, 128, 200):
            key = bytes(i % 253 for i in range(kn))
            for mode in ("hmac", "api-hmac"):
                assert run(mode, algo, key.hex(), data.hex()) == hmac.new(key, data, algo).hexdigest()

vectors = json.loads(Path(sys.argv[1]).read_text())["vectors"]
for v in vectors:
    actual = run("drbg", v["hash"], v["EntropyInput"], v["Nonce"], v["PersonalizationString"],
                 v.get("EntropyInputReseed", ""), v.get("AdditionalInputReseed", ""),
                 *v["AdditionalInput"], str(len(v["ReturnedBits"]) // 2))
    assert actual == v["ReturnedBits"], v
print(f"SHA/HMAC boundary checks and {len(vectors)} NIST HMAC_DRBG groups passed")

handle_vectors = [v for v in vectors if v["hash"] == "sha512" and not v["PersonalizationString"]
                  and not any(v["AdditionalInput"]) and not v.get("AdditionalInputReseed", "")]
assert handle_vectors
for v in handle_vectors:
    assert run("rng", v["hash"], v["EntropyInput"], v["Nonce"],
               v.get("EntropyInputReseed", ""), str(len(v["ReturnedBits"])//2)) == v["ReturnedBits"]
print(f"{len(handle_vectors)} NIST vectors passed through the kmem RNG handle")
