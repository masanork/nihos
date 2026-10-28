// Synthetic event delivery; the target executes native start.S trap/return code.
#include <unicorn/unicorn.h>
#include <unicorn/riscv.h>
#include "../isa_image.h"
#include "oracle.h"

struct Region { uint64_t low, high, peak=0; };
struct WorkerTrace {
    Region boot, irq, peer, font;
    uint64_t instructions=0, next_timer=10000000, timer_injections=0;
    uint32_t trap=0, call_ecall=0, exit_ecall=0, current_address=0, current=0, hb_entry=0;
    bool timers=false, hb_injected=false, deep_injected=false, guard=false, invalid=false, forbidden=false;
    uint64_t min_font_pc=0, invalid_address=0;
    uint64_t guard_sp=0, hb_pc=0, deep_pc=0, deep_sp=0;
    uint32_t forbidden_addresses[24]={};
};
static uint64_t reg(uc_engine*uc,int id) { uint64_t value=0;require(uc_reg_read(uc,id,&value)==UC_ERR_OK,"read register");return value; }
static void set(uc_engine*uc,int id,uint64_t value) { require(uc_reg_write(uc,id,&value)==UC_ERR_OK,"write register"); }
static bool within(Region&r,uint64_t sp) { if(sp<r.low+16||sp>r.high)return false;r.peak=std::max(r.peak,r.high-sp);return true; }
static void deliver(uc_engine*uc,WorkerTrace&t,uint64_t pc,uint32_t cause) {
    uint64_t status=reg(uc,UC_RISCV_REG_MSTATUS);
    set(uc,UC_RISCV_REG_MEPC,pc);
    set(uc,UC_RISCV_REG_MCAUSE,cause);
    // M-mode trap entry: MIE -> MPIE, MIE cleared, previous privilege M.
    status=(status&~UINT64_C(0x1888))|((status&8)<<4)|0x1800;
    set(uc,UC_RISCV_REG_MSTATUS,status);
    set(uc,UC_RISCV_REG_PC,t.trap);
}
static void code(uc_engine*uc,uint64_t address,uint32_t,void*data) {
    auto&t=*(WorkerTrace*)data;++t.instructions;
    uint64_t sp=reg(uc,UC_RISCV_REG_SP);
    uint64_t previous=t.font.peak;
    bool stack=within(t.font,sp)||within(t.irq,sp)||within(t.peer,sp)||within(t.boot,sp);
    if(t.font.peak>previous)t.min_font_pc=address;
    if(!stack){t.guard=true;t.guard_sp=sp;uc_emu_stop(uc);return;}
    for(uint32_t at:t.forbidden_addresses)if(at&&address==at){t.forbidden=true;uc_emu_stop(uc);return;}
    if(address==t.call_ecall||address==t.exit_ecall){deliver(uc,t,address,11);return;}
    if(!t.timers||t.current!=1||sp<t.font.low+16||sp>t.font.high)return;
    bool hb=!t.hb_injected&&address==t.hb_entry;
    bool deep=!t.deep_injected&&t.font.high-sp>=16800;
    bool periodic=t.instructions>=t.next_timer;
    if((hb||deep||periodic)&&(reg(uc,UC_RISCV_REG_MSTATUS)&8)) {
        t.hb_injected|=hb;t.deep_injected|=deep;++t.timer_injections;
        if(hb)t.hb_pc=address;
        if(deep){t.deep_pc=address;t.deep_sp=sp;}
        t.next_timer=t.instructions+10000000;
        deliver(uc,t,address,0x80000010);
    }
}
static void store(uc_engine*,uc_mem_type,uint64_t address,int size,int64_t value,void*data) {
    auto&t=*(WorkerTrace*)data;if(address==t.current_address&&size==4)t.current=(uint32_t)value;
}
static bool invalid(uc_engine*,uc_mem_type,uint64_t address,int,int64_t,void*data) {
    auto&t=*(WorkerTrace*)data;t.invalid=true;t.invalid_address=address;return false;
}
static uint64_t page(uint64_t n){return (n+4095)&~UINT64_C(4095);}
static uint32_t ecall(const Image&image,const char*symbol) {
    uint32_t start=image.symbol(symbol);
    auto programs=(const Elf32_Phdr*)(image.bytes.data()+image.header->e_phoff);
    for(unsigned i=0;i<image.header->e_phnum;i++) {
        const auto&p=programs[i];if(p.p_type!=PT_LOAD||start<p.p_vaddr||start+32>p.p_vaddr+p.p_filesz)continue;
        for(unsigned off=0;off<32;off+=2) { uint32_t instruction;memcpy(&instruction,image.bytes.data()+p.p_offset+start-p.p_vaddr+off,4);if(instruction==0x73)return start+off; }
    }
    require(false,"ECALL instruction not found");return 0;
}
int main(int argc,char**argv) {
    if(argc!=8){fprintf(stderr,"usage: worker-runner worker.elf gothic.ttf mincho.ttf stack-bytes load-mode timers read-yields\n");return 2;}
    Image image(argv[1]);auto gothic=file(argv[2]),mincho=file(argv[3]);
    uint32_t stack_bytes=(uint32_t)strtoul(argv[4],nullptr,10), mode=(uint32_t)strtoul(argv[5],nullptr,10);
    bool timers=!strcmp(argv[6],"1"), reads=!strcmp(argv[7],"1");
    require((stack_bytes==16384||stack_bytes==32768)&&mode<=2,"configuration");
    uc_engine*uc=nullptr;require(uc_open(UC_ARCH_RISCV,UC_MODE_RISCV32,&uc)==UC_ERR_OK,"open RV32");
    auto map=[&](uint64_t at,uint64_t n){require(uc_mem_map(uc,at,page(n),UC_PROT_ALL)==UC_ERR_OK,"map");};
    map(0x41000000,2*1024*1024);map(0x51000000,1024*1024);map(0x52000000,16*1024*1024);
    map(0x54000000,gothic.size());map(0x54800000,mincho.size());map(0x4ff60000,96*1024);map(0x41f00000,4096);
    require((uint64_t)image.header->e_phoff+(uint64_t)image.header->e_phnum*sizeof(Elf32_Phdr)<=image.bytes.size(),"program headers");
    auto programs=(const Elf32_Phdr*)(image.bytes.data()+image.header->e_phoff);
    for(unsigned i=0;i<image.header->e_phnum;i++)if(programs[i].p_type==PT_LOAD) {
        const auto&p=programs[i];require((uint64_t)p.p_offset+p.p_filesz<=image.bytes.size(),"segment bounds");
        require(uc_mem_write(uc,p.p_vaddr,image.bytes.data()+p.p_offset,p.p_filesz)==UC_ERR_OK,"load segment");
    }
    require(uc_mem_write(uc,0x54000000,gothic.data(),gothic.size())==UC_ERR_OK,"load gothic");
    require(uc_mem_write(uc,0x54800000,mincho.data(),mincho.size())==UC_ERR_OK,"load mincho");
    require(uc_mem_protect(uc,0x41000000,2*1024*1024,UC_PROT_READ|UC_PROT_EXEC)==UC_ERR_OK,"protect code");
    require(uc_mem_protect(uc,0x54000000,page(gothic.size()),UC_PROT_READ)==UC_ERR_OK,"protect gothic");
    require(uc_mem_protect(uc,0x54800000,page(mincho.size()),UC_PROT_READ)==UC_ERR_OK,"protect mincho");
    WorkerTrace t;
    t.boot={image.symbol("__stack0_bottom"),image.symbol("__stack0_top")};
    t.irq={image.symbol("__irq_stack0_bottom"),image.symbol("__irq_stack0_top")};
    t.peer={image.symbol("__peer_stack_bottom"),image.symbol("__peer_stack_top")};
    t.font={image.symbol("__font_stack_top")-stack_bytes,image.symbol("__font_stack_top")};
    t.trap=image.symbol("nih_native_trap");t.call_ecall=ecall(image,"nih_riscv_task_call");t.exit_ecall=ecall(image,"nih_riscv_task_exit");
    t.current_address=image.symbol("graphics_worker_current");t.hb_entry=image.symbol("hb_shape_full");t.timers=timers;
    const char*forbidden[]={"_sbrk","_open","_write","_read","_close","_lseek","_exit","_kill","_getpid","__assert_func","abort","_fstat","_isatty","_gettimeofday","_times","_stat","_unlink","_link","_execve","_fork","_wait","graphics_unavailable"};
    for(unsigned i=0;i<sizeof(forbidden)/sizeof(forbidden[0]);i++)t.forbidden_addresses[i]=image.symbol(forbidden[i],false);
    uint32_t input[]={0x54000000,0x54800000,(uint32_t)gothic.size(),(uint32_t)mincho.size(),0x52000000,15596992,mode};
    require(uc_mem_write(uc,0x510ff000,input,sizeof(input))==UC_ERR_OK,"input");
    uint32_t yield_reads=reads;
    uc_mem_write(uc,image.symbol("graphics_worker_stack_bytes"),&stack_bytes,4);
    uc_mem_write(uc,image.symbol("graphics_worker_yield_reads"),&yield_reads,4);
    set(uc,UC_RISCV_REG_SP,t.boot.high);set(uc,UC_RISCV_REG_RA,0x41f00000);set(uc,UC_RISCV_REG_A0,0x510ff000);set(uc,UC_RISCV_REG_GP,image.symbol("__global_pointer$"));
    uc_hook hook1,hook2,hook3;
    require(uc_hook_add(uc,&hook1,UC_HOOK_CODE,(void*)code,&t,1,0)==UC_ERR_OK,"code hook");
    require(uc_hook_add(uc,&hook2,UC_HOOK_MEM_INVALID,(void*)invalid,&t,1,0)==UC_ERR_OK,"invalid hook");
    require(uc_hook_add(uc,&hook3,UC_HOOK_MEM_WRITE,(void*)store,&t,t.current_address,t.current_address+3)==UC_ERR_OK,"current-task hook");
    uc_err error=uc_emu_start(uc,image.header->e_entry,0x41f00000,UINT64_C(600000000),UINT64_C(8000000000));
    GraphicsResult graphics={};WorkerResult worker={};
    uc_mem_read(uc,image.symbol("graphics_result"),&graphics,sizeof(graphics));
    uc_mem_read(uc,image.symbol("graphics_worker_result"),&worker,sizeof(worker));
    bool pass=error==UC_ERR_OK&&reg(uc,UC_RISCV_REG_PC)==0x41f00000&&reg(uc,UC_RISCV_REG_A0)==0&&!t.guard&&!t.forbidden&&!t.invalid&&worker.stage==100&&!worker.failure&&graphics.stage==100&&!graphics.failure;
    const char*status=pass?"pass":t.guard?"stack_guard":t.forbidden?"forbidden_runtime":t.invalid?"invalid_memory":error?"emulator_error":"incomplete";
    printf("{\"status\":\"%s\",\"uc_error\":%d,\"instructions\":%llu,\"last_pc\":%llu,\"invalid_address\":%llu,\"stack_bytes\":%u,\"load_mode\":%u,\"timer_injections\":%llu,\"hb_injected\":%s,\"deep_injected\":%s,\"stack_peaks\":{\"font\":%llu,\"irq\":%llu,\"peer\":%llu,\"boot\":%llu},\"min_font_pc\":%llu,",
        status,(int)error,(unsigned long long)t.instructions,(unsigned long long)reg(uc,UC_RISCV_REG_PC),(unsigned long long)t.invalid_address,stack_bytes,mode,(unsigned long long)t.timer_injections,t.hb_injected?"true":"false",t.deep_injected?"true":"false",(unsigned long long)t.font.peak,(unsigned long long)t.irq.peak,(unsigned long long)t.peer.peak,(unsigned long long)t.boot.peak,(unsigned long long)t.min_font_pc);
    printf("\"worker\":{\"stage\":%u,\"failure\":%u,\"font_rc\":%u,\"peer_progress\":%u,\"timer_traps\":%u,\"call_traps\":%u,\"font_captures\":%u,\"switches\":%u,\"reaped\":%u,\"read_callbacks\":%u,\"read_yields\":%u,\"irq_samples\":%u},",worker.stage,worker.failure,worker.font_rc,worker.peer_progress,worker.timer_traps,worker.call_traps,worker.font_captures,worker.switches,worker.reaped,worker.read_callbacks,worker.read_yields,worker.irq_samples);
    printf("\"graphics\":{\"stage\":%u,\"failure\":%u,\"runs\":%u,\"raw_peak\":%u,\"retained\":%u,\"runtime_malloc_calls\":%u,\"unavailable_calls\":%u,\"hashes\":[",graphics.stage,graphics.failure,graphics.runs,graphics.raw_peak,graphics.retained,graphics.runtime_malloc_calls,graphics.unavailable_calls);
    for(unsigned i=0;i<graphics.runs&&i<16;i++)printf("%s%u",i?",":"",graphics.hashes[i]);
    printf("]},\"guard_sp\":%llu,\"hb_pc\":%llu,\"deep_pc\":%llu,\"deep_sp\":%llu,\"instruction_limit\":8000000000,\"timeout_us\":600000000}\n",(unsigned long long)t.guard_sp,(unsigned long long)t.hb_pc,(unsigned long long)t.deep_pc,(unsigned long long)t.deep_sp);
    uc_close(uc);return pass?0:t.guard?10:3;
}
