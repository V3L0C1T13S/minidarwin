# Stage 6: /usr/share/terminfo -- the `libraries` aggregate's run_tic.sh:
# ncurses/misc/run_tic.sh compiling misc/terminfo.src with `tic -x -s`.
# The compiler is ncursesTic, built for this machine as the aggregate builds
# tic_static; its output is data, the same for either target arch.
#
# Every entry is byte-identical to the corresponding one in macOS 26's
# /usr/share/terminfo (same 2684 names). macOS hardlinks aliases; this tic
# (ncurses_cfg.h has no HAVE_LINK) writes each as its own file, which is all
# the rootfs format could carry anyway.
{ lib, stdenvNoCC, sources, ncursesTic }:

stdenvNoCC.mkDerivation {
  pname = "terminfo";
  version = lib.removePrefix "ncurses-" sources.ncurses.rev;

  src = sources.ncurses;

  dontConfigure = true;
  dontFixup = true;

  buildPhase = ''
    runHook preBuild

    # run_tic.sh ignores tic on PATH unless ../progs/tic exists; otherwise
    # it runs $TIC_PATH (default /usr/bin/tic, the build machine's).
    cd ncurses/misc
    TIC_PATH=${ncursesTic}/bin/tic_static \
    DESTDIR=$out prefix=/usr exec_prefix=/usr bindir=/usr/bin \
    datadir=/usr/share top_srcdir=.. srcdir=. \
      sh ./run_tic.sh

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    n=$(find $out/usr/share/terminfo -type f | wc -l)
    other=$(find $out ! -type f ! -type d | head -5)
    if [ -n "$other" ]; then
      echo "terminfo: expected only files and directories, found:" >&2
      echo "$other" >&2
      exit 1
    fi
    # What libedit reads first: the defaults for TERM unset, and the usual TERMs.
    for t in 64/dumb 76/vt100 78/xterm 78/xterm-256color; do
      [ -s $out/usr/share/terminfo/$t ] || { echo "terminfo: no $t" >&2; exit 1; }
    done
    echo "terminfo: $n entries"

    runHook postInstall
  '';

  meta.description = "The terminfo database, compiled from ncurses' terminfo.src";
}
