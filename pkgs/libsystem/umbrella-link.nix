# Two-pass link breaks cycle; pass1 -undefined dynamic_lookup,
# pass2 -undefined error vs pass1 tree. `absent` lists requiredlibs not produced;
# allowUndefined holes are per-symbol. `upward` (-upward-l) is cycle back-edge hint.
{ lib, targetArch }:

let
  absent = import ./absent-members.nix { inherit targetArch; };

  presentOnly = lib.filter (l: !(absent ? ${l}));
in

{ # Pass-1 tree or null for pass 1.
  stage1 ? null
  # -lsystem_foo from OTHER_LDFLAGS.
, libs ? [ ]
  # -Wl,-upward-lsystem_foo from OTHER_LDFLAGS.
, upward ? [ ]
  # Symbols allowed undefined in pass2 (absent libs); symbol = "why".
, allowUndefined ? { }
}:

[ "-Wl,-umbrella,System" ]
++ (
  if stage1 == null then
  # Pass 1: -undefined dynamic_lookup keeps two-level namespace; exports are the point.
    [ "-Wl,-undefined,dynamic_lookup" ]
  else
    [
      "-L${stage1}/usr/lib/system"
      "-Wl,-undefined,error"
    ]
    ++ map (l: "-l${l}") (presentOnly libs)
    # ld64.lld ignores -upward-l (would silently not link), so use plain -l; loses init-order hint only.
    ++ map (l: "-l${l}") (presentOnly upward)
    # -U is per-symbol; lld needs one flag per symbol.
    ++ map (s: "-Wl,-U,${s}") (lib.attrNames allowUndefined)
)
