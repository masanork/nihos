#ifndef NIHOS_XY_WORKSPACE_H
#define NIHOS_XY_WORKSPACE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Bounded source-store contract. A future sqld adapter must preserve these
 * semantics: immutable revisions, compare-and-swap active head, and a durable
 * receipt before the prepared VM becomes active. Single owner per connection. */
#define XY_SOURCE_LIMIT 4096
#define XY_HISTORY_LIMIT 32
typedef struct XyWorkspaceStore XyWorkspaceStore;
XyWorkspaceStore *xy_workspace_open(const char *path);
void xy_workspace_close(XyWorkspaceStore *store);
const char *xy_workspace_error(XyWorkspaceStore *store);
/* revision=0 reads active source. Empty store returns 0 bytes and revision=0.
 * Unknown nonzero revisions are errors. Source bytes are never truncated. */
int32_t xy_workspace_load(XyWorkspaceStore *store, int64_t revision,
    uint8_t *out, uint32_t capacity, int64_t *out_revision);
int32_t xy_workspace_save(XyWorkspaceStore *store, const uint8_t *source,
    uint32_t length, int64_t expected_head, int64_t *out_revision);
int32_t xy_workspace_select(XyWorkspaceStore *store, int64_t revision, int64_t expected_head);
int32_t xy_workspace_history(XyWorkspaceStore *store, int64_t *out, uint32_t capacity);
#ifdef __cplusplus
}
#endif
#endif
