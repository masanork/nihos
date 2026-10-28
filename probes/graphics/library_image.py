"""Identity-bound pristine RV32 library bank, separate from persistent backing."""
from dataclasses import dataclass
import hashlib
import struct

BANK_START = 0x51000000
BANK_BYTES = 32768


@dataclass(frozen=True)
class Template:
    elf_sha256: str
    data: bytes
    data_sha256: str

    def restore(self, write, loaded_elf_sha256, quiescent):
        if not quiescent:
            raise ValueError("library is still live")
        if loaded_elf_sha256 != self.elf_sha256:
            raise ValueError("wrong loaded ELF identity")
        if len(self.data) != BANK_BYTES or hashlib.sha256(self.data).hexdigest() != self.data_sha256:
            raise ValueError("corrupt pristine image")
        write(BANK_START, self.data)


class Image:
    def __init__(self, data):
        self.data = data
        self.sha256 = hashlib.sha256(data).hexdigest()
        if len(data) < 52 or data[:6] != b'\x7fELF\x01\x01' or struct.unpack_from('<HH', data, 16) != (2, 243):
            raise ValueError("expected executable little-endian RV32 ELF")
        header = struct.unpack_from('<16sHHIIIIIHHHHHH', data)
        _, _, _, _, self.entry, phoff, shoff, _, _, phsize, phcount, shsize, shcount, names_index = header
        if phsize != 32 or shsize != 40 or names_index >= shcount or phoff+phcount*32 > len(data) or shoff+shcount*40 > len(data):
            raise ValueError("invalid ELF table bounds")
        sections = [struct.unpack_from('<10I', data, shoff+i*40) for i in range(shcount)]
        names_header = sections[names_index]
        self.sections = {}
        self.symbols = {}
        def contents(section):
            if section[4]+section[5] > len(data):
                raise ValueError("invalid ELF contents bounds")
            return data[section[4]:section[4]+section[5]]
        names = contents(names_header)
        def string(table, start):
            if start >= len(table) or b'\0' not in table[start:]:
                raise ValueError("invalid ELF string")
            return table[start:].split(b'\0', 1)[0].decode()
        for section in sections:
            name = string(names, section[0])
            self.sections[name] = section
            if section[1] != 8:
                contents(section)
            if section[1] == 2:
                if section[9] != 16 or section[5] % 16 or section[6] >= len(sections):
                    raise ValueError("invalid symbols")
                strings = contents(sections[section[6]])
                for offset in range(section[4], section[4]+section[5], 16):
                    n, address, size, _, _, index = struct.unpack_from('<IIIBBH', data, offset)
                    if n and index:
                        self.symbols[string(strings, n)] = (address, size)
        self.programs = [struct.unpack_from('<8I', data, phoff+i*32) for i in range(phcount)]
        for kind, offset, address, _, length, memory, _, _ in self.programs:
            if kind == 1 and (offset+length > len(data) or length > memory or
                              not (0x41000000 <= address < address+memory <= 0x41200000 or
                                   BANK_START <= address < address+memory <= 0x51028000)):
                raise ValueError("invalid load segment")
        if not any(p[0] == 1 and p[6] & 1 and p[2] <= self.entry < p[2]+p[5] for p in self.programs):
            raise ValueError("entry outside executable segment")
        allowed = {'.library.data', '.library.bss', '.backing.data', '.backing.bss'}
        for name, section in self.sections.items():
            if section[2] & 3 == 3 and section[5] and name not in allowed:
                raise ValueError("unexpected mutable section: " + name)
            if section[2] & 3 == 3 and section[5] and not any(
                    p[0] == 1 and p[6] & 2 and p[2] <= section[3] < section[3]+section[5] <= p[2]+p[5]
                    for p in self.programs):
                raise ValueError("mutable section outside writable load segment")
        template = bytearray(BANK_BYTES)
        extents = []
        for name, kind in (('.library.data', 1), ('.library.bss', 8)):
            section = self.sections.get(name)
            if section is None or section[1] != kind or section[2] != 3 or not section[5] or not BANK_START <= section[3] < section[3]+section[5] <= BANK_START+BANK_BYTES:
                raise ValueError("invalid library bank section")
            extents.append((section[3], section[3]+section[5]))
            if kind == 1:
                template[section[3]-BANK_START:section[3]-BANK_START+section[5]] = contents(section)
        if max(extents[0][0], extents[1][0]) < min(extents[0][1], extents[1][1]):
            raise ValueError("overlapping library sections")
        for name in ('.backing.data', '.backing.bss'):
            s = self.sections.get(name)
            if s is None or not s[2] & 3 == 3 or not BANK_START+BANK_BYTES <= s[3] < s[3]+s[5] <= 0x51028000:
                raise ValueError("kernel backing not isolated")
        self.template = Template(self.sha256, bytes(template), hashlib.sha256(template).hexdigest())

    def initial_symbol(self, name):
        address, size = self.symbols[name]
        if not BANK_START <= address < address+size <= BANK_START+BANK_BYTES:
            raise ValueError("reset symbol outside library bank")
        return address, self.template.data[address-BANK_START:address-BANK_START+size]
