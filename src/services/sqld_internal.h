#ifndef NIHOS_SQLD_INTERNAL_H
#define NIHOS_SQLD_INTERNAL_H
#include "nihos_sqld.h"
#include "sqlite3.h"
#include <stdatomic.h>
struct nih_sqld;
struct nih_sql_file { sqlite3_file base; struct nih_sqld *owner; uint32_t key; int lock, flags; };
struct nih_sqld {
 sqlite3 *db;
 sqlite3_vfs vfs;
 void *store;
 struct nih_sqld_platform platform;
 uint32_t owner, principal, epoch, next_sequence;
 _Atomic uint32_t request_head, request_tail, response_head, response_tail, cancelled;
 struct nih_sqld_request requests[NIH_SQLD_QUEUE];
 struct nih_sqld_response responses[NIH_SQLD_QUEUE];
 struct nih_sql_file *files[2];
 _Atomic uint32_t serial, completed_serial;
 uint32_t handle_serial, handles[16], keys[16];
 unsigned ticks;
 int64_t transaction_deadline;
 sqlite3_int64 previous_heap_limit;
 _Atomic int dead;
 int transaction_expired, fs_dirty, mutation_attempted;
};
int nih_sqld_vfs_init(struct nih_sqld *);
void nih_sqld_vfs_done(struct nih_sqld *);
int nih_sqld_is_owner(struct nih_sqld *);
#endif
