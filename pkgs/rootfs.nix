# Stage 7: assembled rootfs (closed set of Mach-Os + whole-tree checks).
# Contains libSystem (+ members), libc++.1.dylib, libc++abi.dylib and stage 6:
# the shell_cmds, file_cmds, text_cmds, adv_cmds, basic_cmds, system_cmds,
# patch_cmds and misc_cmds tools, awk, and ncurses' own; the libraries they
# link (libedit, libncurses, libutil, libmd); and the terminfo database
# libncurses reads. No dyld yet, so nothing runs.
{ lib
, mkDarwinPackage
, toolchain
, libSystem
, libsystemTree2
, libsystemPass2
, libcxxDylib
, libcxxabiDylib
, ncurses
, terminfo
, libedit
, shellCmds
, libutil
, fileCmds
, libmd
, textCmds
, advCmds
, basicCmds
, systemCmds
, patchCmds
, miscCmds
, awk
, ncursesTools
}:

let
  cmds = [ shellCmds fileCmds textCmds advCmds basicCmds systemCmds patchCmds miscCmds awk ncursesTools ];
  members = [ libSystem libsystemTree2 libcxxDylib libcxxabiDylib ncurses terminfo libedit libutil libmd ] ++ cmds;

  # Union of passthru.allowUndefined from all members.
  declared =
    lib.foldl' (acc: p: acc // (p.allowUndefined or { })) { }
      (lib.attrValues libsystemPass2 ++ [ libcxxDylib libcxxabiDylib ncurses libedit libutil libmd ] ++ cmds);

  # Runtime-provided (dyld defines in loaded process, not in a library).
  runtimeProvided = [ "dyld_stub_binder" ];
in

mkDarwinPackage {
  pname = "minidarwin-rootfs";
  version = libSystem.version;

  inherit toolchain;
  dontUnpack = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/usr/lib/system

    # Checked per file, copied per member: an `install` per file costs
    # seconds over terminfo's 2,684 entries.
    for pkg in ${lib.escapeShellArgs members}; do
      # Files and symlinks (libSystem.dylib etc.).
      while IFS= read -r rel; do
        if [ -e "$out/$rel" ] || [ -L "$out/$rel" ]; then
          echo "rootfs: ''${rel#./} provided by more than one input" >&2
          exit 1
        fi
      done < <(cd $pkg && find . \( -type f -o -type l \) | sort)
      cp -R $pkg/. $out/
      chmod -R u+w $out
    done
    # Keep the exec bit: the release maps it to 0755 vs 0644 (man pages).
    find $out -type d -exec chmod 755 {} +
    find $out -type f -perm -u+x -exec chmod 755 {} +
    find $out -type f ! -perm -u+x -exec chmod 644 {} +

    # Every Mach-O, by its magic (64-bit or fat): the tree also has scripts
    # under bin/ (alias, shar, ...), and executables under libexec/.
    find $out -type f -size +3c | sort | while IFS= read -r f; do
      case $(od -An -tx1 -N4 "$f" | tr -d ' \n') in
        cffaedfe|cafebabe) echo "''${f#$out}" ;;
      esac
    done > $TMPDIR/machos.txt
    ndylibs=$(grep -c '\.dylib$' $TMPDIR/machos.txt || true)
    md_log "rootfs: $ndylibs dylibs, $(( $(wc -l < $TMPDIR/machos.txt) - ndylibs )) executables"

    # Re-verify purity and signature (checked per-library, rechecked for shipped tree).
    while IFS= read -r rel; do
      md_verify_pure   "$out/$rel"
      md_verify_signed "$out/$rel"
    done < $TMPDIR/machos.txt

    runHook postInstall
  '';

  postInstall = ''
        echo "== every dependency must be inside the rootfs"
        fail=0
        while IFS= read -r rel; do
          $OTOOL -L "$out/$rel" | tail -n +2 | awk '{ print $1 }' | sort -u |
          while IFS= read -r dep; do
            # Skip LC_ID_DYLIB (library's own install name).
            [ "$dep" = "$rel" ] && continue
            [ -e "$out$dep" ] || echo "$rel -> $dep"
          done
        done < $TMPDIR/machos.txt > $TMPDIR/dangling.txt
        if [ -s $TMPDIR/dangling.txt ]; then
          echo "rootfs: dependencies that resolve to nothing in the tree:" >&2
          cat $TMPDIR/dangling.txt >&2
          exit 1
        fi
        md_log "rootfs: every LC_LOAD_DYLIB resolves inside the tree"

        echo "== every import must be defined in the rootfs, or declared absent"
        : > $TMPDIR/defined.raw
        : > $TMPDIR/imported.raw
        while IFS= read -r rel; do
          # Umbrella has no symbol table (re-exports only).
          $NM --defined-only "$out/$rel" 2>/dev/null | awk '{ print $NF }' >> $TMPDIR/defined.raw
          $NM -u "$out/$rel" 2>/dev/null | awk '{ print $NF }' >> $TMPDIR/imported.raw
        done < $TMPDIR/machos.txt
        sort -u $TMPDIR/defined.raw  > $TMPDIR/defined.txt
        sort -u $TMPDIR/imported.raw > $TMPDIR/imported.txt
        comm -23 $TMPDIR/imported.txt $TMPDIR/defined.txt > $TMPDIR/unresolved.txt

        printf '%s\n' ${lib.escapeShellArgs (lib.attrNames declared)} | sort -u > $TMPDIR/declared.txt
        printf '%s\n' ${lib.escapeShellArgs runtimeProvided} | sort -u > $TMPDIR/runtime.txt

        md_log "rootfs: $(wc -l < $TMPDIR/defined.txt | tr -d ' ') symbols defined, \
    $(wc -l < $TMPDIR/unresolved.txt | tr -d ' ') imports unresolved, \
    $(wc -l < $TMPDIR/declared.txt | tr -d ' ') declared absent"

        comm -23 $TMPDIR/unresolved.txt $TMPDIR/declared.txt |
          comm -23 - $TMPDIR/runtime.txt > $TMPDIR/unaccounted.txt
        if [ -s $TMPDIR/unaccounted.txt ]; then
          echo "rootfs: imports that nothing defines and no member declared absent:" >&2
          cat $TMPDIR/unaccounted.txt >&2
          echo "(if the library it belongs to is genuinely not built yet, say so in" >&2
          echo " that member's allowUndefined -- one line per symbol, with the" >&2
          echo " library named)" >&2
          exit 1
        fi

        comm -13 $TMPDIR/unresolved.txt $TMPDIR/declared.txt > $TMPDIR/stale.txt
        if [ -s $TMPDIR/stale.txt ]; then
          echo "rootfs: declared absent but resolved by the tree -- drop these:" >&2
          cat $TMPDIR/stale.txt >&2
          exit 1
        fi

        # Unresolved imports by absent library (work list for later stages).
        echo "-- unresolved imports by absent library:"
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList
          (l: syms: ''echo "   ${l}: ${toString (builtins.length syms)}"'')
          (lib.groupBy (s: declared.${s}) (lib.attrNames declared)))}
  '';

  meta.description = "minidarwin rootfs -- everything built so far, at its real paths";
}
