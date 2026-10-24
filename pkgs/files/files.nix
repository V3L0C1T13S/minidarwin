# Stage 6: the `files` project -- the static /private/etc configuration and
# the /usr/share data macOS ships: hosts, services, protocols, shells, ttys,
# gettytab, the word lists, the section 5/7/8 man pages, ...
#
# The project's Makefiles are `install` commands over fixed names, reproduced
# here as install lines per directory. Data only, the same for either target
# arch. Deliberately not reproduced:
#   - `hierarchy*`: the empty directory skeleton with owners and modes; the
#     rootfs format has neither (directories are 0755), and members create the
#     directories they need;
#   - passwd/group/master.passwd: macOS 26 does not install them from here.
#     DarwinDirectory.py only writes plists for Apple's internal `ddtool`;
#   - bsd.sb (built by the sandbox Makefile from an internal tool), the
#     Acknowledgements and LaunchServices preference blobs, the iOS/embedded
#     variants, and `find.codes`-style files Apple creates from /dev/null that
#     are made here as empty files.
{ lib, stdenvNoCC, sources }:

stdenvNoCC.mkDerivation {
  pname = "files";
  version = lib.removePrefix "files-" sources.files.rev;

  src = sources.files;

  dontConfigure = true;
  dontBuild = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall

    etc=$out/private/etc
    for f in afpovertcp.cfg ftpusers gettytab hosts manpaths networks paths \
             protocols rpc services shells ttys; do
      install -Dm644 private/etc/$f $etc/$f
    done
    # `install -c /dev/null`: empty files.
    for f in find.codes hosts.equiv rmtab xtab; do
      install -Dm644 /dev/null $etc/$f
    done
    ln -s ../var/run/resolv.conf $etc/resolv.conf

    share=$out/usr/share
    install -Dm644 usr/share/firmlinks $share/firmlinks
    for f in ascii birthtoken eqnchar flowers getopt man.template mdoc.template operator; do
      install -Dm644 usr/share/misc/$f $share/misc/$f
    done
    for f in connectives propernames web2 web2a README; do
      install -Dm644 usr/share/dict/$f $share/dict/$f
    done
    ln -s web2 $share/dict/words
    for s in 5 7 8; do
      for f in usr/share/man/man$s/*.$s; do
        install -Dm644 $f $share/man/man$s/$(basename $f)
      done
    done

    runHook postInstall
  '';

  meta.description = "Apple's /etc configuration files and /usr/share data";
}
