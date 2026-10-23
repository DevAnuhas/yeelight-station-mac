#!/usr/bin/env python3
"""Read-only PE string/xref/disassembly helper (requires pefile and capstone).

Addresses printed as RVA, independent of ASLR. Example:
  python inspect_pe.py .analysis/windows-app/YeeDaemonLib.dll --strings 'udp_|239'
  python inspect_pe.py .analysis/windows-app/YeeDaemonLib.dll --xref 0x2ff40
  python inspect_pe.py .analysis/windows-app/YeeDaemonLib.dll --start 0x1000 --end 0x1100
"""
import argparse
import hashlib
import re

import capstone
import pefile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary")
    parser.add_argument("--strings")
    parser.add_argument("--xref", type=lambda s: int(s, 0))
    parser.add_argument("--start", type=lambda s: int(s, 0))
    parser.add_argument("--end", type=lambda s: int(s, 0))
    parser.add_argument("--exports", action="store_true")
    args = parser.parse_args()
    pe = pefile.PE(args.binary)
    data = pe.__data__
    base = pe.OPTIONAL_HEADER.ImageBase
    print(f"{args.binary}: imagebase={base:#x} sha256={hashlib.sha256(data).hexdigest()}")
    if args.strings:
        pattern = re.compile(args.strings, re.I)
        for match in re.finditer(rb"[\x20-\x7e]{4,}", data):
            value = match.group().decode("ascii")
            if pattern.search(value):
                print(f"file={match.start():#x} rva={pe.get_rva_from_offset(match.start()):#x} {value!r}")
        for match in re.finditer(rb"(?:[\x20-\x7e]\x00){4,}", data):
            value = match.group().decode("utf-16-le")
            if pattern.search(value):
                print(f"file={match.start():#x} rva={pe.get_rva_from_offset(match.start()):#x} UTF16 {value!r}")
    if args.exports:
        for symbol in pe.DIRECTORY_ENTRY_EXPORT.symbols:
            print(f"{symbol.address:#x} {(symbol.name or b'').decode()}")
    imports = {
        imp.address: imp.name.decode() if imp.name else f"ordinal {imp.ordinal}"
        for dll in getattr(pe, "DIRECTORY_ENTRY_IMPORT", [])
        for imp in dll.imports
    }
    exports = {
        base + sym.address: sym.name.decode() if sym.name else ""
        for sym in getattr(getattr(pe, "DIRECTORY_ENTRY_EXPORT", None), "symbols", [])
    }
    dis = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
    dis.detail = True
    dis.skipdata = True

    def annotate(address):
        if address in imports:
            return "IMPORT " + imports[address]
        if address in exports:
            return "EXPORT " + exports[address]
        if not base <= address < base + pe.OPTIONAL_HEADER.SizeOfImage:
            return ""
        try:
            offset = pe.get_offset_from_rva(address - base)
            candidate = data[offset:offset + 250]
            string = re.match(rb"[\x20-\x7e]{3,}(?:\x00|\r\n)", candidate)
            if string:
                return repr(string.group().rstrip(b"\0").decode("ascii"))
            string = re.match(rb"(?:[\x20-\x7e]\x00){3,}", candidate)
            if string:
                return repr(string.group().decode("utf-16-le"))
        except (pefile.PEFormatError, UnicodeDecodeError):
            pass
        return ""

    if args.start is not None or args.xref is not None:
        for section in pe.sections:
            if not section.Characteristics & 0x20000000:
                continue
            start = args.start if args.start is not None else section.VirtualAddress
            end = args.end if args.end is not None else section.VirtualAddress + section.SizeOfRawData
            code = pe.get_data(start, end - start)
            for ins in dis.disasm(code, base + start):
                if ins.id == 0:
                    continue
                addresses = []
                for op in ins.operands:
                    if op.type == capstone.x86.X86_OP_IMM:
                        addresses.append(op.imm & 0xffffffff)
                    elif op.type == capstone.x86.X86_OP_MEM and not op.mem.base and not op.mem.index:
                        addresses.append(op.mem.disp & 0xffffffff)
                if args.xref is not None and base + args.xref not in addresses:
                    continue
                comments = [a for x in addresses if (a := annotate(x))]
                print(f"{ins.address-base:08x}  {ins.mnemonic:8} {ins.op_str:38} {' ; '.join(comments)}")


if __name__ == "__main__":
    main()
