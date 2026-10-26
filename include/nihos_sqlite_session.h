#ifndef NIHOS_SQLITE_SESSION_H
#define NIHOS_SQLITE_SESSION_H
#include <stddef.h>
#include <stdint.h>

/* Internal, host-qualified service boundary; no application RPC/native ABI yet.
 * Exactly one global owner and memory connection. Zero means success, positive
 * codes are SQLite errors, negative codes are boundary rejections. SQL input is
 * a caller-readable span, 1..512 bytes, with exactly one statement. Result is
 * copied, at most one integer/null scalar; writes returning rows are rejected
 * before execution. No SQLite pointers escape. */
enum { NIH_SQLITE_OWNER = -1, NIH_SQLITE_BUSY = -2,
       NIH_SQLITE_STATE = -3, NIH_SQLITE_LIMIT = -4 };
struct nih_sqlite_result { int64_t value; uint32_t has_value; };
int nih_sqlite_session_open(void);
int nih_sqlite_session_eval(const char *sql, size_t length, struct nih_sqlite_result *result);
int nih_sqlite_session_close(void);
uint32_t nih_sqlite_session_owner(void);
/* Trusted control-plane cancellation; only atomics, never cross-task SQLite.
 * Tokens are globally monotonic across session reopen and never wrap. */
uint32_t nih_sqlite_session_active(void);
int nih_sqlite_session_cancel(uint32_t token);
#ifdef NIH_SQLITE_TESTING
void nih_sqlite_test_fail_after(int point);
int nih_sqlite_test_attempts(void);
int nih_sqlite_test_injected(void);
void nih_sqlite_test_near_token_exhaustion(void);
#endif
#endif
