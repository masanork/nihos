#ifndef NIHOS_GRAPHICS_ISA_IMAGE_H
#define NIHOS_GRAPHICS_ISA_IMAGE_H
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

#endif
