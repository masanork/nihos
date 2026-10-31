#ifndef NIHOS_SQLD_H
#define NIHOS_SQLD_H
#include "nihos_store.h"
/* One serialized owner calls start/step/stop. One producer submits copied
 * requests; responses reserve capacity before execution. No SQLite pointer or
 * client path crosses this boundary. Owner identity comes from the scheduler. */
enum nih_sqld_op { NIH_SQL_QUERY=1, NIH_SQL_EXEC, NIH_SQL_BEGIN, NIH_SQL_COMMIT,
 NIH_SQL_ROLLBACK, NIH_FILE_OPEN, NIH_FILE_READ, NIH_FILE_WRITE, NIH_FILE_RESIZE,
 NIH_FILE_REMOVE, NIH_FILE_SYNC, NIH_FILE_ROLLBACK, NIH_FS_SNAPSHOT,
 NIH_FS_RESTORE, NIH_FS_RELEASE, NIH_FS_COLLECT, NIH_FS_GENERATION, NIH_FILE_LIST,
 NIH_FILE_CLOSE, NIH_FILE_STAT, NIH_FILE_BEGIN, NIH_SQL_LOOKUP, NIH_SQL_CHECK,
 NIH_FS_SPACE, NIH_FILE_VERIFY };
enum { NIH_SQLD_LIMIT=-7, NIH_SQLD_DENIED=-13, NIH_SQLD_STALE=-9,
 NIH_SQLD_UNKNOWN=-115, NIH_SQLD_ERROR=-1000, NIH_SQLD_QUEUE=4, NIH_SQLD_TEXT=512, NIH_SQLD_RESULT=1024 };
struct nih_sqld_request {
 uint32_t epoch, sequence, operation, handle, offset, length, count;
 char text[NIH_SQLD_TEXT];
 char argument[64];
};
struct nih_sqld_response {
 uint32_t epoch, sequence;
 int32_t status; /* 0 or a negative service/storage error; sqlite_code is separate */
 int32_t sqlite_code;
 uint32_t outcome; /* 0=no durable update, 1=committed, 2=unknown */
 uint32_t length;
 char text[NIH_SQLD_RESULT]; /* one bounded S-expression; never truncated */
};
struct nih_sqld_platform {
 void *context;
 uint32_t (*identity)(void *);
 int (*random)(void *, uint8_t *, int);
 int64_t (*time_ms)(void *); /* Julian epoch, as required by SQLite */
 int (*sleep_us)(void *, int);
 int64_t (*monotonic_ms)(void *);
};
size_t nih_sqld_size(void);
size_t nih_sqld_alignment(void);
int nih_sqld_start(void *, size_t, void *store, const struct nih_sqld_platform *, uint32_t principal, uint32_t epoch);
int nih_sqld_submit(void *, uint32_t authenticated_principal, const struct nih_sqld_request *);
int nih_sqld_take(void *, uint32_t authenticated_principal, struct nih_sqld_response *);
int nih_sqld_step(void *);
int nih_sqld_cancel(void *, uint32_t authenticated_principal, uint32_t epoch, uint32_t sequence);
int nih_sqld_stop(void *);
/* In-owner convenience adapter for Scheme/frontends. A target waiting on a
 * separate owner must implement request/completion + scheduler parking instead. */
int nih_sqld_call(void *, uint32_t principal, struct nih_sqld_request *, struct nih_sqld_response *);
#endif
