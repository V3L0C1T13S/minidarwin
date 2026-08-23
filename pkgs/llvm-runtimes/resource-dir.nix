# Clang resource directory for stage 2+: builtin headers + our libclang_rt.osx.a.
# Layout is fixed: clang's Darwin driver appends lib/darwin/libclang_rt.osx.a by name.
{ lib
, runCommand
, bootstrapClang
, compilerRtBuiltins
}:

runCommand "minidarwin-clang-resource-dir"
{
  passthru = { inherit compilerRtBuiltins; };
  meta.description = "clang resource dir with minidarwin's own compiler-rt";
}
  ''
    mkdir -p $out

    # Locate compiler resource dir (versioned path).
    res=$(${bootstrapClang}/bin/clang -print-resource-dir)
    if [ ! -d "$res/include" ]; then
      echo "clang resource dir has no include/ ($res)" >&2
      exit 1
    fi
    ln -s "$res/include" $out/include

    mkdir -p $out/lib/darwin
    ln -s ${compilerRtBuiltins}/lib/darwin/libclang_rt.osx.a \
      $out/lib/darwin/libclang_rt.osx.a
  ''
