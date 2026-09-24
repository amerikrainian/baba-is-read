// Layout-based access to the Lua 5.3.4 stack.
//
// The game statically links Lua 5.3.4 and exports none of the lua_* API, so a
// module cannot link against it. What it can do is receive lua_State* through
// package.loadlib and read the call frame directly, using the struct layouts
// that Lua 5.3.4 fixes for a 64-bit default build:
//
//   lua_State: CommonHeader(next 8, tt 1, marked 1), nci 2, status 1, pad, top @16, l_G @24, ci @32
//   CallInfo:  func @0
//   TValue:    16 bytes, value union then int tt_
//   TString:   header 24 bytes; shrlen @11 (short strings), lnglen @16 (long strings)
//
// Only integers, booleans and nil are ever pushed back: creating a string would
// need the allocator and GC, so results that are text go through files instead.
// The Lua side verifies these offsets at load time (ba_selftest / ba_selftest2).
#ifndef BA_LUASTACK_H
#define BA_LUASTACK_H

#include <stdint.h>
#include <stddef.h>

typedef struct {
    union { void *gc; void *p; int b; void *f; int64_t i; double n; } value_;
    int tt_;
} ba_TValue;

#define BA_TNIL 0
#define BA_TBOOLEAN 1
#define BA_TNUMFLT 3
#define BA_TNUMINT 19
#define BA_TSHRSTR 68
#define BA_TLNGSTR 84

#define BA_L_TOP(L) (*(ba_TValue **)((char *)(L) + 16))
#define BA_L_CI(L) (*(void **)((char *)(L) + 32))
#define BA_CI_FUNC(ci) (*(ba_TValue **)((char *)(ci)))

static inline ba_TValue *ba_base(void *L) { return BA_CI_FUNC(BA_L_CI(L)) + 1; }
static inline int ba_nargs(void *L) { return (int)(BA_L_TOP(L) - ba_base(L)); }

static inline ba_TValue *ba_arg(void *L, int i) {
    if (i < 1 || i > ba_nargs(L)) return NULL;
    return ba_base(L) + (i - 1);
}

// Returns the string argument i, or NULL if absent or not a string.
static inline const char *ba_arg_string(void *L, int i, size_t *len) {
    ba_TValue *v = ba_arg(L, i);
    if (!v) return NULL;
    if (v->tt_ == BA_TSHRSTR) { *len = *((unsigned char *)v->value_.gc + 11); return (const char *)v->value_.gc + 24; }
    if (v->tt_ == BA_TLNGSTR) { *len = *(size_t *)((char *)v->value_.gc + 16); return (const char *)v->value_.gc + 24; }
    return NULL;
}

// Returns the integer argument i, accepting integers, floats and booleans; def otherwise.
static inline int64_t ba_arg_int(void *L, int i, int64_t def) {
    ba_TValue *v = ba_arg(L, i);
    if (!v) return def;
    if (v->tt_ == BA_TNUMINT) return v->value_.i;
    if (v->tt_ == BA_TNUMFLT) return (int64_t)v->value_.n;
    if (v->tt_ == BA_TBOOLEAN) return v->value_.b ? 1 : 0;
    return def;
}

static inline void ba_push_int(void *L, int64_t i) {
    ba_TValue *top = BA_L_TOP(L);
    top->value_.i = i; top->tt_ = BA_TNUMINT;
    BA_L_TOP(L) = top + 1;
}

static inline void ba_push_bool(void *L, int b) {
    ba_TValue *top = BA_L_TOP(L);
    top->value_.b = b ? 1 : 0; top->tt_ = BA_TBOOLEAN;
    BA_L_TOP(L) = top + 1;
}

#endif
