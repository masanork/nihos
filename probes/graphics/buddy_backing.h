#ifndef NIHOS_GRAPHICS_BUDDY_BACKING_H
#define NIHOS_GRAPHICS_BUDDY_BACKING_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Host bridge to unchanged kernel algorithms; no physical PSRAM is touched.
int nih_graphics_backing_init(unsigned char *memory, size_t bytes);
void *nih_graphics_backing_acquire(size_t bytes);
int nih_graphics_backing_release(void *pointer);
size_t nih_graphics_backing_raw_used(void);
size_t nih_graphics_backing_raw_peak(void);
size_t nih_graphics_backing_initial_free(void);
size_t nih_graphics_backing_largest_free(void);
size_t nih_graphics_backing_largest_extent(void);
unsigned nih_graphics_backing_parents(void);
int nih_graphics_backing_retire(void);
int nih_graphics_backing_reopen(void);
int nih_graphics_backing_recovered(void);
unsigned nih_graphics_backing_loan_count(void);
size_t nih_graphics_backing_control_bytes(void);
void *nih_graphics_backing_peer_allocate(size_t bytes);
int nih_graphics_backing_peer_release(void);
// C++ harness initializes a host array, leaving the Zig bridge freestanding.
void graphics_backing_ensure(void);
void graphics_backing_check_report(int all_clients_closed);
#ifdef __cplusplus
}
#endif
#endif
