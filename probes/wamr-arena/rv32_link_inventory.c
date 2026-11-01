/* Link-reachability inventory only. This is never a runnable application:
 * memory callbacks and a valid Wasm binary are deliberately not supplied. */
#include <stddef.h>
#include <stdint.h>
#include "wasm_export.h"
extern int nih_wamr_arena_init(void *, size_t, void *, size_t);
extern void *nih_wamr_arena_alloc(uint32_t, size_t);
extern int nih_wamr_arena_free(uint32_t, void *);
volatile uint8_t nih_wamr_inventory_result;
void nih_wamr_rv32_link_inventory(uint8_t *wasm, uint32_t length, void *runtime, void *linear) {
    RuntimeInitArgs args={0};
    args.mem_alloc_type=Alloc_With_Allocator;
    char error[128];
    if (nih_wamr_arena_init(runtime,128u*1024u,linear,256u*1024u)!=0) return;
    void *scratch=nih_wamr_arena_alloc(0,64);
    if (scratch) (void)nih_wamr_arena_free(0,scratch);
    if (!wasm_runtime_full_init(&args)) return;
    wasm_module_t module=wasm_runtime_load(wasm,length,error,sizeof(error));
    if (module) {
        wasm_module_inst_t inst=wasm_runtime_instantiate(module,16384,0,error,sizeof(error));
        if (inst) {
            wasm_exec_env_t env=wasm_runtime_create_exec_env(inst,16384);
            if (env) {
                wasm_function_inst_t fn=wasm_runtime_lookup_function(inst,"nih_rust_app_frame");
                uint32_t arg[1]={0};
                if (fn && wasm_runtime_call_wasm(env,fn,1,arg)) nih_wamr_inventory_result=(uint8_t)arg[0];
                wasm_runtime_destroy_exec_env(env);
            }
            wasm_runtime_deinstantiate(inst);
        }
        wasm_runtime_unload(module);
    }
    wasm_runtime_destroy();
}
