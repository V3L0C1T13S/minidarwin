// SPDX-License-Identifier: MIT
struct pointer_data { void *p; unsigned long data; };
struct same_layout { char *q; double d; };
struct data_pointer { unsigned long data; void *p; };
template <typename T> constexpr auto summary = __builtin_xnu_type_summary(T);
template <typename T> constexpr const char *signature() {
  return __builtin_xnu_type_signature(T);
}
template <typename L, typename R> constexpr bool compatible =
    __builtin_xnu_types_compatible(L, R);
static_assert(summary<pointer_data> == 6);
static_assert(compatible<pointer_data, same_layout>);
static_assert(!compatible<pointer_data, data_pointer>);
static_assert(__builtin_strcmp(signature<pointer_data>(), "12") == 0);
static_assert(__builtin_strcmp(signature<data_pointer>(), "21") == 0);

// Exercise instantiation, ABI mangling, and code generation as well as folding.
template <typename T> auto layout_tag(T *) -> decltype(__builtin_xnu_type_summary(T)) {
  return __builtin_xnu_type_summary(T);
}
auto emitted_summary() { return layout_tag(static_cast<pointer_data *>(nullptr)); }
const char *emitted_signature() { return signature<pointer_data>(); }

struct virtual_base { void *p; };
struct base : virtual virtual_base { long b; };
struct derived : base { long d; };
struct polymorphic { virtual ~polymorphic(); long data; };
static_assert(__builtin_strcmp(signature<base>(), "121") == 0);
static_assert(__builtin_strcmp(signature<derived>(), "1221") == 0);
static_assert(__builtin_strcmp(signature<polymorphic>(), "12") == 0);
