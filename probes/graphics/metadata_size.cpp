#include "lazy_pool.h"
// Optional RV32 compile-only check, not a native runtime or allocator port.
static_assert(sizeof(LazyPool) <= 8192, "controller exceeds SRAM target");
extern "C" {
extern const unsigned nih_graphics_controller_bytes = sizeof(LazyPool);
}
