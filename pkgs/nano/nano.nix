# Apple's nano.xcodeproj target `nano`, shipped under its pico name.
{ lib
, mkCmds
, sources
, toolchain
, ncurses
}:

mkCmds {
  pname = "nano";
  src = sources.nano;
  inherit toolchain;
  sourceLists = import ./nano-sources.nix;

  tools.nano = {
    product = "pico";
    libraries = [{ pkg = ncurses; l = "ncurses"; }];
    # Directory Services' passwd enumeration is not built into libSystem yet.
    allowUndefined = {
      "_getpwuid" = "system_info";
      "_getpwent" = "system_info";
      "_endpwent" = "system_info";
    };
    man = { "doc/nano.1" = "/usr/share/man/man1/pico.1"; };
    links = {
      "/usr/bin/nano" = "/usr/bin/pico";
      "/usr/share/man/man1/nano.1" = "/usr/share/man/man1/pico.1";
    };
  };

  # nano.xcodeproj Release settings; config.h is checked into Apple's tree.
  cflags = [ "-Os" "-I." ]; # config.h is included with angle brackets
  defines = [ "HAVE_CONFIG_H" ''SYSCONFDIR="/etc"'' ];
  ldflags = [ "-Wl,-dead_strip" ];

  extraInstall = ''
    install -Dm644 nanorc $out/etc/nanorc
    install -Dm644 doc/nanorc.5 $out/usr/share/man/man5/nanorc.5
  '';
}
