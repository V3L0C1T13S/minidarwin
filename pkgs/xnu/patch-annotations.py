#!/usr/bin/env python3
"""Preserve XNU allocation semantics using Clang's public annotate attribute."""
from pathlib import Path
import sys

for root in map(Path, sys.argv[1:]):
    for relative in ("sys/cdefs.h", "sys/_types/_uintptr_t.h"):
        path = root / relative
        text = path.read_text()
        assert "xnu_usage_semantics" in text, path
        text = text.replace("__has_attribute(xnu_usage_semantics)", "__has_attribute(annotate)")
        text = text.replace('xnu_usage_semantics("pointer", "data")', 'annotate("xnu:dual")')
        text = text.replace('xnu_usage_semantics("pointer")', 'annotate("xnu:pointer")')
        text = text.replace('xnu_usage_semantics("data")', 'annotate("xnu:data")')
        path.write_text(text)
