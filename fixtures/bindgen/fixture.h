// Small, hand-written fixture for the `natyv get` binding generator's Stage 1
// (see ~/.claude/plans/lexical-wishing-penguin.md). Deliberately hits exactly
// the CLAUDE.md-confirmed proof surface and nothing else: an opaque handle
// (create/destroy), one struct (used as an out-param), one enum-shaped status
// return, and one callback registration + a real invocation path to prove the
// round trip. No standard-library includes on purpose -- the generator must
// work against a bare header, and this project's own reflection spike found
// that even a completely dependency-free header still produces a handful of
// platform-injected decls translate-c can't resolve, so the fixture doesn't
// need to *add* any real-world header noise to prove that case is handled.

typedef struct FixtureHandle FixtureHandle;

typedef enum {
    FIXTURE_OK = 0,
    FIXTURE_ERROR = 1,
} FixtureStatus;

typedef struct {
    int x;
    int y;
} FixturePoint;

typedef void (*FixtureCallback)(int value, void *user_data);

FixtureHandle *fixture_create(int initial);
void fixture_destroy(FixtureHandle *handle);

// Zero-parameter function -- Stage 2.2 regression coverage for a real bug
// found while binding real zlib's `zlibCompileFlags(void)`: a bound
// function with no parameters has an empty generated Request struct, so
// naively always declaring `const req = parsed.value;` produced a real
// "unused local constant" compile error the first time a genuine
// zero-arg C function was ever bound (every prior fixture function took
// at least one parameter, so this case was never exercised before).
int fixture_ping(void);

// Out-param + enum-shaped return: writes the handle's current value into
// *out_point (x = current value, y = current value doubled) and reports
// FIXTURE_ERROR without writing anything if handle is NULL.
FixtureStatus fixture_get_point(FixtureHandle *handle, FixturePoint *out_point);

// Callback registration: stores cb/user_data on the handle. fixture_trigger
// invokes the stored callback (if any) with (value, user_data) -- this is
// the real round trip a generated host<->guest dispatch bridge needs to
// reproduce, not just a registration call that's never actually invoked.
void fixture_set_callback(FixtureHandle *handle, FixtureCallback cb, void *user_data);
void fixture_trigger(FixtureHandle *handle, int value);

// Stage 2.9 regression coverage: mirrors real zlib's own `crc32(uLong,
// const Bytef*, uInt) -> uLong` shape exactly -- a wide unsigned
// accumulator in, a const byte buffer + its own length in, a wide
// unsigned result out. Proves the new byte-buffer-in-param + wide/
// unsigned-int marshaling machinery against a hermetic fixture before
// Stage 2.9's own separate real-zlib end-to-end proof.
unsigned long fixture_checksum(unsigned long seed, const unsigned char *data, unsigned int len);

// Stage 2.10 regression coverage: mirrors real zlib's own
// `compress(Bytef *dest, uLongf *destLen, const Bytef *source, uLong
// sourceLen) -> int` shape exactly -- a non-const out-buffer + its own
// in/out capacity/length pointer, then a const in-buffer + its own plain
// length. Writes each of the first `min(*dest_len, source_len)` bytes of
// `source`, each doubled mod 256 (a trivial, easy-to-verify-independently
// transform -- this fixture isn't trying to compress anything for real),
// into `dest`, and sets `*dest_len` to the real number of bytes actually
// written. Returns 0 normally, -1 if `*dest_len` is 0 on entry (mirrors
// a real C function reporting a real error via its return code).
int fixture_pack(unsigned char *dest, unsigned long *dest_len, const unsigned char *source, unsigned long source_len);

// Deliberately NOT in `allowlist` (see Reflect.zig) -- exists so
// Reflect.zig's own tests can prove `describe` rejects a function-like
// macro cleanly (`error.GenericFunction`) rather than crashing. A
// single-expression function-like macro like this one translates into a
// real, callable Zig `pub inline fn`, but a *generic* one (`anytype`
// params, since a macro has no concrete parameter types until invoked) --
// confirmed by a real spike, not assumed.
#define FIXTURE_DOUBLE(x) ((x) * 2)

// Deliberately NOT in `allowlist` -- exists so `TranslateC.zig`'s own
// Stage 2.8 tests can prove the translate-c pre-pass gives a clean,
// natyv-attributed "this is a constant, not a function" diagnostic for a
// plain object-like macro, rather than the confusing "access of inactive
// union field" a dev would otherwise hit deep inside Reflect.describe.
#define FIXTURE_VERSION 1
