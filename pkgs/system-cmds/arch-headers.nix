# Only pinned source headers, private to arch; no framework implementation.
{ runCommand, sources }:
runCommand "arch-framework-headers" { } ''
  mkdir -p $out/CoreFoundation
  cp ${sources.CF}/*.h $out/CoreFoundation/
  chmod u+w $out/CoreFoundation/CoreFoundation.h
  cat > $out/CoreFoundation/CoreFoundation.h <<'EOF'
  #include <CoreFoundation/CFArray.h>
  #include <CoreFoundation/CFData.h>
  #include <CoreFoundation/CFDictionary.h>
  #include <CoreFoundation/CFPropertyList.h>
  #include <CoreFoundation/CFString.h>
  EOF
''
