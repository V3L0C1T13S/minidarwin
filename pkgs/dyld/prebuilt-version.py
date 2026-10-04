#!/usr/bin/env python3
"""Version MiniDarwin's prebuilt-loader format from target record layouts."""
import hashlib
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
records = text.split("*** Dumping AST Record Layout")
names = ("dyld4::PrebuiltLoader", "dyld4::PrebuiltLoaderSet",
         "dyld4::ObjCBinaryInfo", "mach_o::LinkedDylibAttributes",
         "dyld4::Loader::DylibPatch", "dyld4::Loader::FileValidationInfo",
         "dyld3::MapView<", "dyld3::MultiMapView<",
         "objc::SelectorHashTable")
selected = []
for name in names:
    matches = [r.strip() for r in records if r.strip()
               and name in r.strip().splitlines()[0] and "sizeof=" in r]
    if not matches:
        raise SystemExit(f"missing prebuilt-loader record layout: {name}")
    selected.extend(sorted(matches))
digest = hashlib.md5("\n".join(selected).encode()).hexdigest()[:8]
Path(sys.argv[2]).write_text(f"#define PREBUILTLOADER_VERSION 0x{digest}\n")
