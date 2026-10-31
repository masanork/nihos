#ifndef NIHOS_XY_LEARNING_H
#define NIHOS_XY_LEARNING_H
#include <stdbool.h>
#include <stdint.h>
/* The host retains catalogue and library bytes until the next xy_host_live_init. */
bool xy_host_learning_bind(const uint8_t *data, uint32_t length,
                           const uint8_t *library, uint32_t library_length);
int32_t xy_host_learning_page(uint32_t section, uint32_t start, uint32_t end);
int32_t xy_host_learning_choice(uint32_t ordinal, uint8_t *out, uint32_t cap);
bool xy_host_learning_open(uint32_t ordinal);
void xy_host_learning_leave(void);
bool xy_host_learning_insert(const uint8_t *text, uint32_t length, bool replace);
void xy_host_learning_key(uint8_t key);
/* action: 0 run, 1 reset VM, 2 original code, 3 code/notes, 4 undo. */
int32_t xy_host_learning_action(uint32_t action);
/* field: 0 code, 1 notes, 2 result, 3 ID, 4 notice, 5 reference (not a grade). */
int32_t xy_host_learning_copy(uint32_t field, uint8_t *out, uint32_t cap);
#endif
