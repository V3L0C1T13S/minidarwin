# top.xcodeproj Release: top plus its static libtop sampling library.
# Framework imports are explicitly absent, like other userland imports from
# libraries MiniDarwin cannot supply yet. No host frameworks are linked.
{ lib, callPackage, mkCmds, sources, toolchain, ncurses, ncursesPanel, libutil }:

let
  frameworkHeaders = callPackage ./framework-headers.nix { };
in
mkCmds {
  pname = "top";
  src = sources.top;
  inherit toolchain;
  sourceLists.top = (import ./top-sources.nix) ++ (import ./libtop-sources.nix);

  # libtop relies on transitive includes from the full CF umbrella.
  postPatch = ''
    substituteInPlace libtop.c \
      --replace-fail '#include <limits.h>' '#include <limits.h>
    #include <errno.h>
    #include <inttypes.h>'
  '';

  tools.top = {
    libraries = [
      { pkg = ncurses; l = "ncurses"; }
      { pkg = ncursesPanel; l = "panel"; }
      { pkg = libutil; l = "util"; }
    ];
    man = { "top.1" = "/usr/share/man/man1/top.1"; };
    allowUndefined = {
      "_CFDictionaryApplyFunction" = "CoreFoundation";
      "_CFDictionaryContainsKey" = "CoreFoundation";
      "_CFDictionaryCreateMutable" = "CoreFoundation";
      "_CFDictionaryGetValue" = "CoreFoundation";
      "_CFDictionarySetValue" = "CoreFoundation";
      "_CFNumberGetValue" = "CoreFoundation";
      "_CFRelease" = "CoreFoundation";
      "___CFConstantStringClassReference" = "CoreFoundation";
      "_kCFAllocatorDefault" = "CoreFoundation";
      "_IOMainPort" = "IOKit";
      "_IOIteratorNext" = "IOKit";
      "_IOIteratorReset" = "IOKit";
      "_IOObjectRelease" = "IOKit";
      "_IORegistryEntryCreateCFProperties" = "IOKit";
      "_IOServiceGetMatchingServices" = "IOKit";
      "_IOServiceMatching" = "IOKit";
      "_getpwuid" = "system_info";
      "_getpwnam" = "system_info";
      "_endpwent" = "system_info";
    };
  };

  # Apple's sources share tentative tsamp definitions (pre-clang-11 default).
  cflags = [ "-std=gnu11" "-Os" "-fcommon" "-fblocks" "-Werror=format-nonliteral" "-I${frameworkHeaders}" ];
  defines = [ "TOP_ANONYMOUS_MEMORY" ];
  ldflags = [ "-Wl,-dead_strip" ];
}
