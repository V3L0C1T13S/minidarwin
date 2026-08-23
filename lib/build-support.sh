# Helpers for minidarwin target derivations. Drives clang directly, no xcodebuild/make.

set -euo pipefail

export LC_ALL=C

md_log() { echo "[minidarwin] $*" >&2; }

# md_sources <root> <pattern>... - find-style -path globs, sorted.
md_sources() {
  local root="$1"; shift
  local pat args=()
  for pat in "$@"; do
    args+=( -o -path "$root/$pat" )
  done
  find "$root" -type f \( "${args[@]:1}" \) | sort
}

# md_glob <path>... - print existing files, sorted. Shell glob stops at '/', unlike find -path '*'.
md_glob() {
  local f out=()
  for f in "$@"; do
    [ -e "$f" ] && out+=( "$f" )
  done
  [ "${#out[@]}" -gt 0 ] || return 0
  printf '%s\n' "${out[@]}" | sort
}

# md_exclude <regex> - filter file list on stdin.
md_exclude() {
  grep -Ev "$1" || true
}

# md_cmake_list <CMakeLists.txt> <VAR> - print entries of set(VAR ...) block.
md_cmake_list() {
  local file="$1" var="$2" out
  # The closing paren may be indented (libunwind) or at column 0 (compiler-rt).
  out=$(sed -n "/^set($var\$/,/^[[:space:]]*)[[:space:]]*\$/p" "$file" |
        sed -e '1d' -e '$d' -e 's/#.*//' \
            -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' |
        grep -v '^\${' | grep -v '^$' || true)
  if [ -z "$out" ]; then
    echo "md_cmake_list: no entries for set($var) in $file" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

# md_compile <outdir> <compiler> <flags...> -- <file>... - hash avoids same-name collisions.
md_compile() {
  local outdir="$1"; shift
  local cc="$1"; shift
  local flags=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do flags+=( "$1" ); shift; done
  shift # past --

  mkdir -p "$outdir"
  local jobs="${NIX_BUILD_CORES:-1}"
  [ "$jobs" -gt 0 ] || jobs=1

  local f rel tag obj pids=()
  for f in "$@"; do
    rel="${f#"$MD_SRCROOT"/}"
    tag=$(printf '%s' "$rel" | cksum | cut -d' ' -f1)
    obj="$outdir/${tag}-$(basename "${f%.*}").o"

    local langflags=()
    case "$f" in
      # -fno-dollars-in-identifiers: with -fdollars, $SYSCALL_CONSTRUCT_MDEP is one token.
      *.s|*.S) langflags=( -x assembler-with-cpp -fno-dollars-in-identifiers ) ;;
      *.cpp|*.cc|*.cxx) langflags=( -x c++ ) ;;
      *.m)  langflags=( -x objective-c ) ;;
      *.mm) langflags=( -x objective-c++ ) ;;
    esac

    "$cc" "${flags[@]}" "${langflags[@]}" -c "$f" -o "$obj" &
    pids+=( $! )
    if [ "${#pids[@]}" -ge "$jobs" ]; then
      wait "${pids[0]}"
      pids=( "${pids[@]:1}" )
    fi
  done
  local p
  for p in "${pids[@]}"; do wait "$p"; done
}

# md_alias_flags <alias-list> - translate Apple -alias_list to -Wl,-alias (lld ignores -alias_list).
md_alias_flags() {
  local file="$1" sym alias n=0
  while read -r sym alias _rest; do
    case "$sym" in ''|'#'*) continue ;; esac
    if [ -z "$alias" ]; then
      echo "md_alias_flags: $file: no alias for $sym" >&2
      return 1
    fi
    printf -- '-Wl,-alias,%s,%s\n' "$sym" "$alias"
    n=$((n + 1))
  done < "$file"
  if [ "$n" -eq 0 ]; then
    echo "md_alias_flags: no entries in $file" >&2
    return 1
  fi
}

# md_archive <out.a> <objdir>
md_archive() {
  local out="$1" objdir="$2"
    find "$objdir" -name '*.o' | sort | xargs "$AR" crsD "$out"
}

# md_dylib <out.dylib> <install_name> <objdir> [extra link args...]
md_dylib() {
  local out="$1" iname="$2" objdir="$3"; shift 3
  local objs=()
  while IFS= read -r o; do objs+=( "$o" ); done < <(find "$objdir" -name '*.o' | sort)
  "$CC" -dynamiclib \
    -install_name "$iname" \
    -compatibility_version "${MD_COMPAT_VERSION:-1.0.0}" \
    -current_version "${MD_CURRENT_VERSION:-1.0.0}" \
    -o "$out" "${objs[@]}" "$@"
}

# md_verify_pure <macho> - fail if binary links outside target rootfs.
md_verify_pure() {
  local f="$1"
  local bad
  # llvm-objdump in otool mode needs classic flags.
  bad=$("$OTOOL" -L "$f" 2>/dev/null | tail -n +2 |
        grep -oE '(/nix/store|/Applications|/Library|/System/Library/Frameworks)[^ ]*' || true)
  if [ -n "$bad" ]; then
    echo "IMPURE: $f links against host paths:" >&2
    echo "$bad" >&2
    return 1
  fi
}

# md_verify_symbols <file> <symbol>... - fail if any symbol missing.
md_verify_symbols() {
  local f="$1"; shift
  local defined missing=() s
  defined="$(mktemp)"
  "$NM" --defined-only "$f" | awk '{ print $NF }' | sort -u > "$defined"
  for s in "$@"; do
    grep -qx -- "$s" "$defined" || missing+=( "$s" )
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "MISSING SYMBOLS in $f: ${missing[*]}" >&2
    return 1
  fi
}

# md_verify_reexports <macho> <install-name>... - check LC_REEXPORT_DYLIB.
md_verify_reexports() {
  local f="$1"; shift
  local deps missing=() l
  deps="$(mktemp)"
  "$OTOOL" -L "$f" | tail -n +2 | grep 'reexport' | awk '{ print $1 }' | sort -u > "$deps"
  for l in "$@"; do
    grep -qx -- "$l" "$deps" || missing+=( "$l" )
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "NOT REEXPORTED by $f: ${missing[*]}" >&2
    return 1
  fi
}

# md_verify_signed <macho>
md_verify_signed() {
  local f="$1"
  if ! "$OTOOL" -l "$f" | grep -q LC_CODE_SIGNATURE; then
    echo "UNSIGNED: $f has no LC_CODE_SIGNATURE (arm64 macOS will refuse it)" >&2
    return 1
  fi
}
