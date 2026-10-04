// SPDX-License-Identifier: MIT
// MiniDarwin implementation of XNU's documented eight-byte granule layout.
#ifndef MINIDARWIN_XNU_TYPE_LAYOUT_H
#define MINIDARWIN_XNU_TYPE_LAYOUT_H

#include "clang/AST/ASTContext.h"
#include "clang/AST/Attr.h"
#include "clang/AST/DeclCXX.h"
#include "clang/AST/RecordLayout.h"
#include "clang/Sema/Sema.h"
#include "clang/Basic/TargetInfo.h"
#include <optional>
#include <string>
#include <vector>

namespace clang {
namespace minidarwin {

inline unsigned semantics(const Decl *D) {
  if (!D) return 0;
  for (const auto *A : D->specific_attrs<AnnotateAttr>()) {
    if (A->getAnnotation() == "xnu:pointer") return 1;
    if (A->getAnnotation() == "xnu:data") return 2;
    if (A->getAnnotation() == "xnu:dual") return 4;
  }
  return 0;
}

class TypeLayout {
  ASTContext &C;
  std::vector<unsigned char> Granules;

  bool mark(uint64_t Offset, uint64_t Bits, unsigned Kind) {
    if (!Bits) return true;
    if ((Offset + Bits + 63) / 64 > Granules.size()) return false;
    for (uint64_t I = Offset / 64; I <= (Offset + Bits - 1) / 64; ++I)
      Granules[I] |= Kind;
    return true;
  }

  bool walk(QualType T, uint64_t Offset, unsigned Override = 0,
            bool BaseSubobject = false) {
    if (T->isIncompleteType()) return false;
    uint64_t Bits = C.getTypeSize(T);
    if (Override) return mark(Offset, Bits, Override);
    // Inspect typedef declarations before desugaring, preserving annotations
    // on uintptr_t and other deliberately pointer-shaped integer aliases.
    if (const auto *TD = dyn_cast<TypedefType>(T.getTypePtr()))
      return walk(TD->desugar(), Offset, semantics(TD->getDecl()), BaseSubobject);
    if (const auto *AT = dyn_cast<AtomicType>(T.getTypePtr()))
      return walk(AT->getValueType(), Offset);
    QualType Desugared = T.getSingleStepDesugaredType(C);
    if (Desugared != T) return walk(Desugared, Offset, 0, BaseSubobject);
    if (const auto *AT = C.getAsConstantArrayType(T)) {
      uint64_t Stride = C.getTypeSize(AT->getElementType());
      uint64_t Count = AT->getSize().getZExtValue();
      for (uint64_t I = 0; I < Count; ++I)
        if (!walk(AT->getElementType(), Offset + I * Stride)) return false;
      return true;
    }
    if (const auto *RT = T->getAs<RecordType>()) {
      const RecordDecl *RD = RT->getDecl()->getDefinition();
      if (!RD) return false;
      const ASTRecordLayout &L = C.getASTRecordLayout(RD);
      if (const auto *CD = dyn_cast<CXXRecordDecl>(RD)) {
        if (L.hasOwnVFPtr() && !mark(Offset, C.getTypeSize(C.VoidPtrTy), 1))
          return false;
        for (const auto &B : CD->bases()) {
          if (B.isVirtual()) continue;
          const auto *BD = B.getType()->getAsCXXRecordDecl();
          if (!walk(B.getType(), Offset + L.getBaseClassOffset(BD).getQuantity() * 8, 0, true))
            return false;
        }
        // Only the complete object's layout locates virtual bases. A base's
        // standalone virtual-base offsets do not describe its subobject.
        if (!BaseSubobject) for (const auto &B : CD->vbases()) {
          const auto *BD = B.getType()->getAsCXXRecordDecl();
          if (!walk(B.getType(), Offset + L.getVBaseClassOffset(BD).getQuantity() * 8, 0, true))
            return false;
        }
      }
      unsigned I = 0;
      for (const FieldDecl *F : RD->fields()) {
        uint64_t FieldOffset = Offset + L.getFieldOffset(I++);
        QualType FT = F->getType();
        // Flexible-array members contribute no bytes to sizeof the header.
        if (FT->isIncompleteArrayType()) continue;
        unsigned Kind = semantics(F);
        if (F->isBitField()) {
          if (!mark(FieldOffset, F->getBitWidthValue(), Kind ? Kind : 2))
            return false;
        } else if (!walk(FT, FieldOffset, Kind)) return false;
      }
      return true;
    }
    if (T->isPointerType() || T->isBlockPointerType() || T->isReferenceType())
      return mark(Offset, Bits, 1);
    if (T->isScalarType() || T->isVectorType()) return mark(Offset, Bits, 2);
    return false;
  }

public:
  explicit TypeLayout(ASTContext &C) : C(C) {}
  std::optional<std::string> signature(QualType T) {
    // This implementation targets x86_64, which has no authenticated pointers.
    if (C.getTargetInfo().getTriple().getArch() != llvm::Triple::x86_64)
      return std::nullopt;
    if (T->isVoidType()) return std::string();
    if (T->isIncompleteType() || T->isVariablyModifiedType()) return std::nullopt;
    uint64_t Bits = C.getTypeSize(T);
    if (Bits > 8 * 1024 * 1024) return std::nullopt;
    Granules.assign((Bits + 63) / 64, 0);
    if (!walk(T, 0)) return std::nullopt;
    std::string Result;
    for (unsigned char G : Granules) Result += "0123456789abcdef"[G];
    return Result;
  }
};

std::optional<std::string> signature(Sema &S, QualType T, SourceLocation Loc);

} // namespace minidarwin
} // namespace clang
#endif
