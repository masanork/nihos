#include "buddy_backing.h"
#include <stdio.h>
#include <stdlib.h>

// 32 MiB layout: half of the 30 MiB tail, minus guards/bootstrap/test buffers.
// This array emulates an available owner heap, not a graphics reservation.
alignas(64) static unsigned char owner_heap[15596992];
static bool initialized;
extern "C" void graphics_backing_ensure() {
    if (initialized) return;
    if (nih_graphics_backing_init(owner_heap, sizeof(owner_heap))) abort();
    initialized = true;
}
extern "C" void graphics_backing_check_report(int all_clients_closed) {
    if (nih_graphics_backing_parents() > 2) abort();
    if (all_clients_closed && (nih_graphics_backing_parents() != 1 ||
        nih_graphics_backing_raw_used() != 64 * 1024 + 256)) abort();
    fprintf(stderr, "GRAPHICS_BUDDY raw_used=%zu raw_peak=%zu parents=%u loans=%u initial_free=%zu control_host=%zu\n",
        nih_graphics_backing_raw_used(), nih_graphics_backing_raw_peak(),
        nih_graphics_backing_parents(), nih_graphics_backing_loan_count(),
        nih_graphics_backing_initial_free(), nih_graphics_backing_control_bytes());
}
