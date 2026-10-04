// SPDX-License-Identifier: MIT
// Fixed frontend integration boundary; layout implementation links separately.
#include "clang/Sema/Sema.h"
#include <optional>
#include <string>
namespace clang::minidarwin {
std::optional<std::string> signature(Sema &, QualType, SourceLocation);
}
