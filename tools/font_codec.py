"""Lossless row dictionary encoding for the automatic reader's 16x16 font."""
from collections import Counter
import struct
def encode(raw):
    if not raw or len(raw)%36:raise ValueError('invalid raw font')
    rows=[r for at in range(0,len(raw),36) for r in struct.unpack('<16H',raw[at+4:at+36])]
    dictionary=[r for r,_ in Counter(rows).most_common(4095)]
    dictionary+= [0]*(4095-len(dictionary));lookup={r:i for i,r in enumerate(dictionary)}
    entries=bytearray();payload=bytearray()
    for at in range(0,len(raw),36):
        code=struct.unpack_from('<I',raw,at)[0];entries+=code.to_bytes(3,'little')+len(payload).to_bytes(3,'little')
        bits=0;used=0
        for row in struct.unpack('<16H',raw[at+4:at+36]):
            index=lookup.get(row,4095);bits|=index<<used;used+=12
            if index==4095:bits|=row<<used;used+=16
        assert used%8==0
        payload+=bits.to_bytes(used//8,'little')
    return b'NCF1'+struct.pack('<IHBx',len(raw)//36,4095,12)+struct.pack('<4095H',*dictionary)+entries+payload
def decode(data):
    if len(data)<12 or data[:4]!=b'NCF1':raise ValueError('invalid row font header')
    count,rows,bits=struct.unpack_from('<IHB',data,4)
    if not 1<=count<=12000 or rows!=4095 or bits!=12 or data[11]:raise ValueError('unsupported row font profile')
    table=12+rows*2;payload=table+count*6
    if payload>len(data):raise ValueError('truncated row font')
    result=bytearray();last=-1;expected=0
    for i in range(count):
        at=table+i*6;code=int.from_bytes(data[at:at+3],'little');offset=int.from_bytes(data[at+3:at+6],'little')
        if code<=last or code>0x10ffff or 0xd800<=code<=0xdfff or offset!=expected:raise ValueError('invalid glyph index/offset')
        last=code;pos=(payload+offset)*8;bitmap=[]
        def read(n):
            nonlocal pos
            if pos+n>len(data)*8:raise ValueError('truncated glyph')
            value=sum(((data[(pos+j)//8]>>((pos+j)%8))&1)<<j for j in range(n));pos+=n;return value
        for _ in range(16):
            index=read(12);bitmap.append(read(16) if index==4095 else struct.unpack_from('<H',data,12+index*2)[0])
        expected=pos//8-payload;result+=struct.pack('<I16H',code,*bitmap)
    if payload+expected!=len(data):raise ValueError('trailing compressed font data')
    return bytes(result)
