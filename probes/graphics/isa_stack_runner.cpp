// Standalone RV32 ISA oracle, not an ESP32-P4/peripheral emulator.
#include <unicorn/unicorn.h>
#include <unicorn/riscv.h>
#include "link_oracle.h"
#include "elf32_layout.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vector>

static void require(bool good,const char*why) { if(!good){fprintf(stderr,"ISA runner: %s\n",why);exit(2);} }
static std::vector<unsigned char> file(const char*path) {
    FILE*f=fopen(path,"rb");require(f,"open input");fseek(f,0,SEEK_END);long n=ftell(f);require(n>0,"input length");rewind(f);
    std::vector<unsigned char> bytes((size_t)n);require(fread(bytes.data(),1,bytes.size(),f)==bytes.size(),"read input");fclose(f);return bytes;
}
struct Image {
    std::vector<unsigned char> bytes;
    const Elf32_Ehdr *header;
    explicit Image(const char*path):bytes(file(path)) {
        require(bytes.size()>=sizeof(Elf32_Ehdr),"ELF header");header=(const Elf32_Ehdr*)bytes.data();
        require(!memcmp(header->e_ident,ELFMAG,4)&&header->e_ident[EI_CLASS]==ELFCLASS32&&header->e_ident[EI_DATA]==ELFDATA2LSB&&header->e_machine==EM_RISCV&&header->e_phentsize==32&&header->e_shentsize==40,"ELF32 little-endian RISC-V required");
        require((uint64_t)header->e_shoff+(uint64_t)header->e_shnum*sizeof(Elf32_Shdr)<=bytes.size(),"section bounds");
    }
    uint32_t symbol(const char*name,bool needed=true) const {
        auto sections=(const Elf32_Shdr*)(bytes.data()+header->e_shoff);
        for(unsigned i=0;i<header->e_shnum;i++) {
            const auto&s=sections[i];if(s.sh_type!=SHT_SYMTAB)continue;
            require(s.sh_link<header->e_shnum&&s.sh_entsize==sizeof(Elf32_Sym),"symbol header");
            const auto&str=sections[s.sh_link];require((uint64_t)str.sh_offset+str.sh_size<=bytes.size()&&(uint64_t)s.sh_offset+s.sh_size<=bytes.size(),"symbol bounds");
            auto symbols=(const Elf32_Sym*)(bytes.data()+s.sh_offset);auto names=(const char*)bytes.data()+str.sh_offset;
            for(unsigned j=0;j<s.sh_size/sizeof(Elf32_Sym);j++) {
                const auto&t=symbols[j];if(t.st_shndx==SHN_UNDEF||t.st_name>=str.sh_size)continue;
                if(!strcmp(names+t.st_name,name))return t.st_value;
            }
        }
        require(!needed,name);return 0;
    }
};
struct Trace {
    uint64_t top=0,base=0,min_sp=UINT64_MAX,min_pc=0,instructions=0;
    bool guard=false,invalid=false,forbidden=false;
    uint64_t invalid_address=0;
    uint32_t forbidden_addresses[24]={};
    uint32_t path_addresses[4]={};
    uint64_t path_entries[4]={};
    uint32_t peak_stage=0, result_address=0;
};
static void code(uc_engine*uc,uint64_t address,uint32_t,void*data) {
    auto&t=*(Trace*)data;++t.instructions;
    uint64_t sp=0;uc_reg_read(uc,UC_RISCV_REG_SP,&sp);
    if(sp<t.min_sp){t.min_sp=sp;t.min_pc=address;uc_mem_read(uc,t.result_address+4,&t.peak_stage,4);}
    if(sp<t.base+16||sp>t.top){t.guard=true;uc_emu_stop(uc);}
    for(uint32_t at:t.forbidden_addresses)if(at&&address==at){t.forbidden=true;uc_emu_stop(uc);}
    for(unsigned i=0;i<4;i++)if(t.path_addresses[i]&&address==t.path_addresses[i])++t.path_entries[i];
}
static bool invalid(uc_engine*,uc_mem_type,uint64_t address,int,int64_t,void*data) {
    auto&t=*(Trace*)data;t.invalid=true;t.invalid_address=address;return false;
}
static uint64_t page(uint64_t n){return (n+4095)&~UINT64_C(4095);}
int main(int argc,char**argv) {
    if(argc!=5&&argc!=6){fprintf(stderr,"usage: isa-stack-runner oracle.elf gothic.ttf mincho.ttf stack-bytes [load-mode]\n");return 2;}
    Image image(argv[1]);auto gothic=file(argv[2]),mincho=file(argv[3]);
    uint32_t stack_bytes=(uint32_t)strtoul(argv[4],nullptr,10);
    require(stack_bytes>=128&&stack_bytes<=65536&&!(stack_bytes%16),"stack size");
    uint32_t mode=0;
    if(argc==6) { char*end=nullptr;unsigned long n=strtoul(argv[5],&end,10);require(*argv[5]&&!*end&&n<=2,"load mode");mode=(uint32_t)n; }
    uc_engine*uc=nullptr;require(uc_open(UC_ARCH_RISCV,UC_MODE_RISCV32,&uc)==UC_ERR_OK,"open Unicorn RV32");
    auto map=[&](uint64_t at,uint64_t n){require(uc_mem_map(uc,at,page(n),UC_PROT_ALL)==UC_ERR_OK,"memory map");};
    map(0x41000000,2*1024*1024);map(0x51000000,1024*1024);
    map(0x52000000,16*1024*1024);map(0x54000000,gothic.size());map(0x54800000,mincho.size());
    map(0x55001000,stack_bytes);map(0x41f00000,4096);
    require((uint64_t)image.header->e_phoff+(uint64_t)image.header->e_phnum*sizeof(Elf32_Phdr)<=image.bytes.size(),"program header bounds");
    auto programs=(const Elf32_Phdr*)(image.bytes.data()+image.header->e_phoff);
    for(unsigned i=0;i<image.header->e_phnum;i++)if(programs[i].p_type==PT_LOAD) {
        const auto&p=programs[i];require((uint64_t)p.p_offset+p.p_filesz<=image.bytes.size(),"segment bounds");
        require(uc_mem_write(uc,p.p_vaddr,image.bytes.data()+p.p_offset,p.p_filesz)==UC_ERR_OK,"load segment");
    }
    require(uc_mem_write(uc,0x54000000,gothic.data(),gothic.size())==UC_ERR_OK,"load gothic");
    require(uc_mem_write(uc,0x54800000,mincho.data(),mincho.size())==UC_ERR_OK,"load mincho");
    require(uc_mem_protect(uc,0x41000000,2*1024*1024,UC_PROT_READ|UC_PROT_EXEC)==UC_ERR_OK,"code read-only");
    require(uc_mem_protect(uc,0x54000000,page(gothic.size()),UC_PROT_READ)==UC_ERR_OK,"font read-only");
    require(uc_mem_protect(uc,0x54800000,page(mincho.size()),UC_PROT_READ)==UC_ERR_OK,"font read-only");
    Trace trace;trace.top=0x55001000+page(stack_bytes);trace.base=trace.top-stack_bytes;
    uint32_t input[]={0x54000000,0x54800000,(uint32_t)gothic.size(),(uint32_t)mincho.size(),0x52000000,15596992,mode};
    require(uc_mem_write(uc,0x510ff000,input,sizeof(input))==UC_ERR_OK,"write inputs");
    uint64_t sp=trace.top,ra=0x41f00000,a0=0x510ff000,gp=image.symbol("__global_pointer$");
    uc_reg_write(uc,UC_RISCV_REG_SP,&sp);uc_reg_write(uc,UC_RISCV_REG_RA,&ra);uc_reg_write(uc,UC_RISCV_REG_A0,&a0);uc_reg_write(uc,UC_RISCV_REG_GP,&gp);
    const char*forbidden[]={"_sbrk","_open","_write","_read","_close","_lseek","_exit","_kill","_getpid","__assert_func","abort",
        "_fstat","_isatty","_gettimeofday","_times","_stat","_unlink","_link","_execve","_fork","_wait","graphics_unavailable"};
    for(unsigned i=0;i<sizeof(forbidden)/sizeof(forbidden[0]);i++)trace.forbidden_addresses[i]=image.symbol(forbidden[i],false);
    const char*paths[]={"af_autofitter_load_glyph","af_cjk_metrics_init_widths","af_latin_metrics_init_widths","TT_RunIns"};
    for(unsigned i=0;i<4;i++) { trace.path_addresses[i]=image.symbol(paths[i]); }
    trace.result_address=image.symbol("graphics_result");
    uc_hook hook1,hook2;
    require(uc_hook_add(uc,&hook1,UC_HOOK_CODE,(void*)code,&trace,1,0)==UC_ERR_OK,"instruction hook");
    require(uc_hook_add(uc,&hook2,UC_HOOK_MEM_INVALID,(void*)invalid,&trace,1,0)==UC_ERR_OK,"memory hook");
    constexpr uint64_t timeout_us=UINT64_C(600000000), instruction_limit=UINT64_C(8000000000);
    uc_err error=uc_emu_start(uc,image.header->e_entry,ra,timeout_us,instruction_limit);
    uint64_t pc=0,returned=0;uc_reg_read(uc,UC_RISCV_REG_PC,&pc);uc_reg_read(uc,UC_RISCV_REG_A0,&returned);
    GraphicsResult result={};uc_mem_read(uc,image.symbol("graphics_result"),&result,sizeof(result));
    bool passed=error==UC_ERR_OK&&pc==ra&&returned==0&&result.stage==100&&!result.failure&&!trace.guard&&!trace.forbidden;
    bool refused=error==UC_ERR_OK&&pc==ra&&returned==20&&result.stage==90&&result.allocation_failures&&!result.failure&&!trace.guard&&!trace.forbidden;
    const char*status=passed?"pass":refused?"allocation_refused":trace.guard?"stack_guard":trace.forbidden?"forbidden_runtime":trace.invalid?"invalid_memory":error?"emulator_error":"incomplete";
    printf("{\"status\":\"%s\",\"uc_error\":%d,\"stack_bytes\":%u,\"stack_peak\":%llu,\"min_pc\":%llu,\"instructions\":%llu,\"last_pc\":%llu,\"invalid_address\":%llu,\"stage\":%u,\"failure\":%u,\"runs\":%u,\"raw_peak\":%u,\"retained\":%u,\"runtime_malloc_calls\":%u,\"unavailable_calls\":%u,\"hashes\":[",
        status,(int)error,stack_bytes,(unsigned long long)(trace.top-trace.min_sp),(unsigned long long)trace.min_pc,(unsigned long long)trace.instructions,(unsigned long long)pc,(unsigned long long)trace.invalid_address,result.stage,result.failure,result.runs,result.raw_peak,result.retained,result.runtime_malloc_calls,result.unavailable_calls);
    for(unsigned i=0;i<result.runs&&i<16;i++)printf("%s%u",i?",":"",result.hashes[i]);
    printf("],\"load_mode\":%u,\"peak_stage\":%u,\"path_entries\":{",mode,trace.peak_stage);
    for(unsigned i=0;i<4;i++)printf("%s\"%s\":%llu",i?",":"",paths[i],(unsigned long long)trace.path_entries[i]);
    printf("},\"controller_bytes\":%u,\"record_capacity\":%u,\"record_peak\":%u,\"record_failures\":%u,\"allocation_failures\":%u,\"instruction_limit\":%llu,\"timeout_us\":%llu}\n",result.controller_bytes,result.record_capacity,result.record_peak,result.record_failures,result.allocation_failures,(unsigned long long)instruction_limit,(unsigned long long)timeout_us);
    uc_close(uc);return passed?0:refused?20:trace.guard?10:3;
}
