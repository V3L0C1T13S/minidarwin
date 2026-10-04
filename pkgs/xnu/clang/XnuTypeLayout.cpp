// SPDX-License-Identifier: MIT
#include "XnuTypeLayout.h"

namespace clang::minidarwin {
std::optional<std::string> signature(Sema &S, QualType T, SourceLocation Loc) {
  auto Result = TypeLayout(S.Context).signature(T);
  if (!Result) {
    unsigned ID = S.getDiagnostics().getCustomDiagID(
        DiagnosticsEngine::Error, "unsupported type in MiniDarwin XNU layout builtin: %0");
    S.Diag(Loc, ID) << T;
  }
  return Result;
}
}
