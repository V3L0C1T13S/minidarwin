#!/usr/bin/env python3
"""Apply the small LLVM 21 frontend integration, with exact anchors."""
from pathlib import Path

def replace(name, old, new):
    path = Path(name)
    text = path.read_text()
    assert text.count(old) == 1, (name, old, text.count(old))
    path.write_text(text.replace(old, new))

replace("include/clang/Basic/TokenKinds.def",
        "UNARY_EXPR_OR_TYPE_TRAIT(__builtin_ptrauth_type_discriminator, PtrAuthTypeDiscriminator, KEYALL)",
        """UNARY_EXPR_OR_TYPE_TRAIT(__builtin_ptrauth_type_discriminator, PtrAuthTypeDiscriminator, KEYALL)
UNARY_EXPR_OR_TYPE_TRAIT(__builtin_xnu_type_signature, XnuTypeSignature, KEYALL)
UNARY_EXPR_OR_TYPE_TRAIT(__builtin_xnu_type_summary, XnuTypeSummary, KEYALL)
TYPE_TRAIT_2(__builtin_xnu_types_compatible, XnuTypesCompatible, KEYALL)""")
replace("include/clang/Parse/Parser.h",
        "ExprResult ParseBuiltinPtrauthTypeDiscriminator();",
        "ExprResult ParseBuiltinPtrauthTypeDiscriminator();\n  ExprResult ParseBuiltinXnuType();")
replace("lib/Parse/ParseExpr.cpp",
        "ExprResult Parser::ParseBuiltinPtrauthTypeDiscriminator() {",
        """ExprResult Parser::ParseBuiltinXnuType() {
  auto Kind = Tok.is(tok::kw___builtin_xnu_type_signature)
      ? UETT_XnuTypeSignature : UETT_XnuTypeSummary;
  SourceLocation Loc = ConsumeToken();
  BalancedDelimiterTracker T(*this, tok::l_paren);
  if (T.expectAndConsume()) return ExprError();
  TypeResult Ty = ParseTypeName();
  if (Ty.isInvalid()) { SkipUntil(tok::r_paren, StopAtSemi); return ExprError(); }
  SourceLocation EndLoc = Tok.getLocation();
  if (T.consumeClose()) return ExprError();
  return Actions.ActOnUnaryExprOrTypeTraitExpr(Loc, Kind, true,
      Ty.get().getAsOpaquePtr(), SourceRange(Loc, EndLoc));
}

ExprResult Parser::ParseBuiltinPtrauthTypeDiscriminator() {""")
replace("lib/Parse/ParseExpr.cpp",
        "  case tok::kw___builtin_ptrauth_type_discriminator:\n    return ParseBuiltinPtrauthTypeDiscriminator();",
        """  case tok::kw___builtin_ptrauth_type_discriminator:
    return ParseBuiltinPtrauthTypeDiscriminator();
  case tok::kw___builtin_xnu_type_signature:
  case tok::kw___builtin_xnu_type_summary:
    return ParseBuiltinXnuType();""")
replace("lib/Sema/SemaExpr.cpp", '#include "clang/AST/ASTContext.h"',
        '#include "clang/AST/ASTContext.h"\n#include "XnuTypeLayout.h"')
replace("lib/Sema/SemaTypeTraits.cpp", '#include "clang/Sema/Sema.h"',
        '#include "clang/Sema/Sema.h"\n#include "XnuTypeLayout.h"')
replace("lib/Sema/SemaExpr.cpp",
        """  QualType T = TInfo->getType();

  if (!T->isDependentType() &&""",
        """  QualType T = TInfo->getType();
  if (ExprKind == UETT_XnuTypeSignature || ExprKind == UETT_XnuTypeSummary) {
    QualType ResultTy = ExprKind == UETT_XnuTypeSignature
        ? Context.getPointerType(Context.CharTy.withConst()) : Context.getSizeType();
    if (T->isDependentType())
      return new (Context) UnaryExprOrTypeTraitExpr(
          ExprKind, TInfo, ResultTy, OpLoc, R.getEnd());
    auto Sig = minidarwin::signature(*this, T, OpLoc);
    if (!Sig) return ExprError();
    if (ExprKind == UETT_XnuTypeSummary) {
      uint64_t Mask = 0;
      for (char G : *Sig) Mask |= 1ULL << (G <= '9' ? G - '0' : G - 'a' + 10);
      return IntegerLiteral::Create(Context,
          llvm::APInt(Context.getTypeSize(ResultTy), Mask), ResultTy, OpLoc);
    }
    QualType ArrayTy = Context.getConstantArrayType(Context.CharTy.withConst(),
        llvm::APInt(64, Sig->size() + 1), nullptr, ArraySizeModifier::Normal, 0);
    auto *SL = StringLiteral::Create(Context, *Sig, StringLiteralKind::Ordinary,
        false, ArrayTy, OpLoc);
    return ImpCastExprToType(SL, ResultTy, CK_ArrayToPointerDecay);
  }

  if (!T->isDependentType() &&""")
replace("lib/Sema/SemaTypeTraits.cpp",
        "  case BTT_TypeCompatible: {",
        """  case BTT_XnuTypesCompatible: {
    if (Self.Context.hasSameUnqualifiedType(LhsT, RhsT)) return true;
    if (LhsT->isVoidType() || RhsT->isVoidType()) return false;
    auto L = minidarwin::signature(Self, LhsT, KeyLoc);
    auto R = minidarwin::signature(Self, RhsT, KeyLoc);
    return L && R && *L == *R;
  }
  case BTT_TypeCompatible: {""")
replace("lib/AST/ItaniumMangle.cpp",
        "    case UETT_SizeOf:\n      Out << 's';",
        """    case UETT_XnuTypeSignature:
      MangleExtensionBuiltin(SAE, "__builtin_xnu_type_signature");
      break;
    case UETT_XnuTypeSummary:
      MangleExtensionBuiltin(SAE, "__builtin_xnu_type_summary");
      break;
    case UETT_SizeOf:
      Out << 's';""")
