#ifndef NIHOS_GRAPHICS_ELF32_LAYOUT_H
#define NIHOS_GRAPHICS_ELF32_LAYOUT_H
// ELF32 file-format structures for the host runner (macOS has no elf.h).
#include <stdint.h>
struct Elf32_Ehdr {
    unsigned char e_ident[16];
    uint16_t e_type,e_machine;
    uint32_t e_version,e_entry,e_phoff,e_shoff,e_flags;
    uint16_t e_ehsize,e_phentsize,e_phnum,e_shentsize,e_shnum,e_shstrndx;
};
struct Elf32_Phdr { uint32_t p_type,p_offset,p_vaddr,p_paddr,p_filesz,p_memsz,p_flags,p_align; };
struct Elf32_Shdr { uint32_t sh_name,sh_type,sh_flags,sh_addr,sh_offset,sh_size,sh_link,sh_info,sh_addralign,sh_entsize; };
struct Elf32_Sym { uint32_t st_name,st_value,st_size;unsigned char st_info,st_other;uint16_t st_shndx; };
static_assert(sizeof(Elf32_Ehdr)==52&&sizeof(Elf32_Phdr)==32&&sizeof(Elf32_Shdr)==40&&sizeof(Elf32_Sym)==16,"ELF32 layout");
#define ELFMAG "\177ELF"
enum { EI_CLASS=4,EI_DATA=5,ELFCLASS32=1,ELFDATA2LSB=1,EM_RISCV=243,SHT_SYMTAB=2,SHN_UNDEF=0,PT_LOAD=1 };
#endif
