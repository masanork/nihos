/* Compile-only target layout/type fingerprint. No SQLite or OS is executed. */
#include <stddef.h>
#include <stdint.h>
#include "sqlite3.h"
#include "nihos_sqlite_session.h"
_Static_assert(sizeof(void *) == 4, "RV32 probe requires 32-bit pointers");
_Static_assert(sizeof(sqlite3_int64) == 8, "SQLite integer ABI");
const uint32_t nih_sqlite_rv32_abi[] = {
    0x53514c33, SQLITE_VERSION_NUMBER, sizeof(void *), sizeof(long),
    sizeof(sqlite3_mem_methods), sizeof(sqlite3_vfs), sizeof(struct nih_sqlite_result),
    offsetof(struct nih_sqlite_result, value), offsetof(struct nih_sqlite_result, has_value),
    _Generic(&sqlite3_column_double, sqlite3_int64 (*)(sqlite3_stmt *, int): 1, default: 0),
    _Generic(((sqlite3_vfs *)0)->xCurrentTime, int (*)(sqlite3_vfs *, sqlite3_int64 *): 1, default: 0)
};
