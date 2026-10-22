import pathlib
import struct

def imports(path):
    data=pathlib.Path(path).read_bytes()
    pe=struct.unpack_from('<I',data,60)[0]
    assert data[pe:pe+4]==b'PE\0\0'
    count=struct.unpack_from('<H',data,pe+6)[0]
    size=struct.unpack_from('<H',data,pe+20)[0]
    opt=pe+24;magic=struct.unpack_from('<H',data,opt)[0]
    directories=opt+(112 if magic==0x20b else 96)
    sections=[]
    for i in range(count):
        off=opt+size+i*40
        virtual_size,rva,raw_size,raw=struct.unpack_from('<IIII',data,off+8)
        sections.append((rva,max(virtual_size,raw_size),raw))
    def offset(rva):
        for start,length,raw in sections:
            if start<=rva<start+length:return raw+rva-start
        raise ValueError('Unmapped PE RVA')
    rva,length=struct.unpack_from('<II',data,directories+8)
    result=[]
    if not rva:return result
    pos=offset(rva)
    while any(data[pos:pos+20]):
        name_rva=struct.unpack_from('<I',data,pos+12)[0];name=offset(name_rva)
        result.append(data[name:data.index(b'\0',name)].decode('ascii').lower());pos+=20
    return result

def closure(root,entry):
    root=pathlib.Path(root);files={p.name.lower():p for p in root.iterdir() if p.is_file()}
    pending=[entry.lower()];result={}
    while pending:
        name=pending.pop()
        if name in result or name not in files:continue
        result[name]=imports(files[name])
        pending.extend(result[name])
    return result
