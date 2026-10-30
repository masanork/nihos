#ifndef NIHOS_GRAPHICS_WORKER_ORACLE_H
#define NIHOS_GRAPHICS_WORKER_ORACLE_H
#include "../link_oracle.h"
struct WorkerResult {
    uint32_t stage, failure, font_rc, peer_progress, timer_traps, call_traps;
    uint32_t font_captures, switches, reaped, read_callbacks, read_yields;
    uint32_t font_stack_min, font_stack_max, irq_samples;
};
extern "C" {
extern WorkerResult graphics_worker_result;
extern uint32_t graphics_worker_current;
extern uint32_t graphics_worker_stack_bytes;
extern uint32_t graphics_worker_yield_reads;
}
#endif
