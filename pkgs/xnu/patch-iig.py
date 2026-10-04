#!/usr/bin/env python3
"""Resolve literal array-bound macros in the pinned IIG parser."""
from pathlib import Path
p = Path('src/parse.cpp')
s = p.read_text()
def change(old, new):
    global s
    assert s.count(old) == 1, old
    s = s.replace(old, new)
change('#include <map>', '#include <map>\n#include <sstream>')
change('parseParam(const std::string &raw, Param &p, std::string &error)',
       'parseParam(const std::string &raw, Param &p, std::string &error, const std::map<std::string, int> &bounds)')
change('  for (size_t i = toks.size(); i-- > 0;) {', '''  size_t nameEnd = toks.size();
  for (size_t i = 0; i < toks.size(); i++) if (toks[i] == "[") { nameEnd = i; break; }
  for (size_t i = nameEnd; i-- > 0;) {''')
change('        p.arrayCount = atoi(toks[i].c_str());', '''        p.arrayCount = atoi(toks[i].c_str());
        auto bound = bounds.find(toks[i]);
        if (!p.arrayCount && bound != bounds.end()) p.arrayCount = bound->second;
        if (p.arrayCount <= 0) { error = "unknown or invalid array bound: " + toks[i]; return false; }''')
change('parseMethod(const std::string &decl, Method &m, std::string &error)',
       'parseMethod(const std::string &decl, Method &m, std::string &error, const std::map<std::string, int> &bounds)')
change('parseParam(part, p, perr)', 'parseParam(part, p, perr, bounds)')
change('parseMethod(d, m, merr)', 'parseMethod(d, m, merr, out.enumConstants)')
change('  /* Fixed-array typedefs used', '''  // Capture positive numeric object-like macros used as array bounds.
  {
    std::istringstream lines(blankComments(text));
    std::string line;
    while (std::getline(lines, line)) {
      auto t = tokenize(line);
      if (t.size() == 4 && t[0] == "#" && t[1] == "define") {
        char *end = nullptr;
        long value = strtol(t[3].c_str(), &end, 0);
        if (*end == '\\0' && value > 0 && value <= 1048576)
          out.enumConstants[t[2]] = static_cast<int>(value);
      }
    }
  }

  /* Fixed-array typedefs used''')
p.write_text(s)

# IOUserServer validates the Mach envelope and supplies kernelContent before
# calling Dispatch. The userland decoder is intentionally excluded from XNU.
p = Path('src/codegen.cpp')
s = p.read_text()
old = '    IORPCMessage * msg = IORPCMessageFromMach(rpc.message, false);\\n\\n'
assert s.count(old) == 2
s = s.replace(old, '#if KERNEL\\n    IORPCMessage * msg = rpc.kernelContent;\\n'
              '#else\\n    IORPCMessage * msg = IORPCMessageFromMach(rpc.message, false);\\n#endif\\n'
              '    if (!msg) return kIOReturnBadArgument;\\n\\n')
p.write_text(s)
