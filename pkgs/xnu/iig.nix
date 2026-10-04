{ lib, stdenv, cmake, sources, python3 }:
stdenv.mkDerivation {
  pname = "minidarwin-iig";
  version = "0.1-${builtins.substring 0 7 sources.iig_tools.rev}";
  src = sources.iig_tools;
  nativeBuildInputs = [ cmake python3 ];
  postPatch = ''python3 ${./patch-iig.py}'';
  doCheck = true;
  checkPhase = ''
    cat > bounds.iig <<'EOF'
    #define ReasonCapacity 1024
    class KERNEL TestServer : public IOService {
    public:
      virtual kern_return_t Panic(const char reason[ReasonCapacity]);
    };
    EOF
    ./iig --def bounds.iig --header bounds.h --impl bounds.cpp
    grep -q 'char __reason\[1024\]' bounds.cpp
    grep -q 'const char \* reason' bounds.h
    grep -q 'msg = rpc.kernelContent' bounds.cpp
    # Keep the declaration's bound undefined, while preserving the macro.
    sed 's/reason\[ReasonCapacity\]/reason[UndefinedCapacity]/' bounds.iig > invalid.iig
    if ./iig --def invalid.iig --header invalid.h --impl invalid.cpp; then
      echo 'IIG accepted an undefined array bound' >&2; exit 1
    fi
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 iig $out/bin/iig
    install -Dm644 ../LICENSE $out/share/licenses/iig/LICENSE
    runHook postInstall
  '';
  meta.description = "IOKit interface generator for kernel-side DriverKit interfaces";
  meta.license = lib.licenses.bsd3;
}
