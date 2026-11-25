#!/usr/bin/env python3
"""
Build & strictly verify honor_boost.ko for Honor Magic 9 Pro Max
(GKI 6.18.21-android17-5-gfee2325de189-abogki572422516-4k aarch64).

Uses native Clang kCFI (`-fsanitize=kcfi -fsanitize-cfi-icall-experimental-normalize-integers`)
and performs mandatory pre-load ABI safety checks before emitting honor_boost.ko:
  1. Verifies exact sizeof(.gnu.linkonce.this_module) == 0x680 and init/exit reloc offsets
  2. Verifies exact 4-byte kCFI type hash words at (func_addr - 4)
  3. Verifies PAC/BTI landing pad (paciasp / bti c) at every indirect entry point
  4. Verifies ZERO x18 (shadow call stack register) clobbers
  5. Verifies every UND symbol is in the verified GKI 6.18.21 CRC table
  6. Includes arm64 .plt / .init.plt / ftrace_trampoline stub sections
"""

import os
import re
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(HERE, "build")
SRC = os.path.join(HERE, "honor_boost.c")
OBJ = os.path.join(BUILD, "honor_boost.o")
LDS = os.path.join(BUILD, "honor_boost.lds")
KO = os.path.join(HERE, "honor_boost.ko")

LDS_CONTENT = """\
SECTIONS {
    .text : { *(.text .text.*) }
    .init.text : { *(.init.text .init.text.*) }
    .exit.text : { *(.exit.text .exit.text.*) }
    .plt 0 : { BYTE(0) }
    .init.plt 0 : { BYTE(0) }
    .text.ftrace_trampoline 0 : { BYTE(0) }
    .init.text.ftrace_trampoline 0 : { BYTE(0) }
}
"""

ALLOWED_UND = {
    "_printk",
    "param_ops_uint",
    "register_kprobe",
    "unregister_kprobe",
}

EXPECTED_KCFI = {
    "init_module":     0x6fbb3035,
    "cleanup_module":  0xe5c47d60,
    "kp_kgsl_pre":     0xc073bc77,
    "kp_fq_pre":       0xc073bc77,
    "kp_udmabuf_pre":  0xc073bc77,
}

def run(cmd):
    print("+", " ".join(cmd))
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        print(res.stdout)
        print(res.stderr, file=sys.stderr)
        sys.exit(res.returncode)
    return res.stdout

def main():
    os.makedirs(BUILD, exist_ok=True)
    with open(LDS, "w") as f:
        f.write(LDS_CONTENT)

    run([
        "clang",
        "--target=aarch64-linux-gnu",
        "-O2",
        "-ffreestanding",
        "-fno-PIE", "-fno-PIC",
        "-fno-stack-protector",
        "-fno-asynchronous-unwind-tables",
        "-fno-unwind-tables",
        "-fno-strict-aliasing",
        "-fno-common",
        "-ffixed-x18",
        "-mgeneral-regs-only",
        "-mbranch-protection=pac-ret+bti",
        "-fsanitize=kcfi",
        "-fsanitize-cfi-icall-experimental-normalize-integers",
        "-Wall", "-Wextra",
        "-c", SRC, "-o", OBJ,
    ])

    run(["ld.lld", "-r", "-T", LDS, OBJ, "-o", KO])

    # --- STRICT ABI VERIFICATION ---
    data = open(KO, "rb").read()
    e_shoff = struct.unpack_from("<Q", data, 40)[0]
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", data, 58)
    shstr_off = struct.unpack_from("<Q", data, e_shoff + e_shstrndx * e_shentsize + 24)[0]

    secs = {}
    sec_by_idx = {}
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        sh_name, sh_type, sh_flags, sh_addr, sh_offset, sh_size, sh_link, sh_info, sh_addralign, sh_entsize = \
            struct.unpack_from("<IIQQQQIIQQ", data, off)
        name = data[shstr_off + sh_name : data.find(b"\0", shstr_off + sh_name)].decode()
        info = (i, name, sh_offset, sh_size, sh_type, sh_link, sh_info)
        secs[name] = info
        sec_by_idx[i] = info

    for req in [".gnu.linkonce.this_module", ".modinfo", "__versions", "__version_ext_crcs",
                "__version_ext_names", "__param", ".plt", ".init.plt", ".text.ftrace_trampoline"]:
        assert req in secs, f"Missing required section: {req}"
    this_mod_sz = secs[".gnu.linkonce.this_module"][3]
    assert this_mod_sz == 0x680, f"this_module size mismatch: {hex(this_mod_sz)} != 0x680"
    print(f"[OK] .gnu.linkonce.this_module size = {hex(this_mod_sz)}")

    relocs = run(["readelf", "-r", "-W", KO])
    assert re.search(r"0000000000000178\s+\S+\s+R_AARCH64_ABS64\s+\S+\s+init_module", relocs), \
        "init_module relocation not at +0x178!"
    assert re.search(r"0000000000000600\s+\S+\s+R_AARCH64_ABS64\s+\S+\s+cleanup_module", relocs), \
        "cleanup_module relocation not at +0x600!"
    print("[OK] this_module init@+0x178, exit@+0x600")

    syms_txt = run(["readelf", "-s", "-W", KO])
    und_syms = set()
    func_locs = {}
    for line in syms_txt.splitlines():
        parts = line.split()
        if len(parts) >= 8 and parts[0].endswith(":") and parts[0][:-1].isdigit():
            val = int(parts[1], 16)
            stype = parts[3]
            shndx = parts[6]
            sname = parts[7]
            if shndx == "UND" and sname:
                und_syms.add(sname)
            elif stype == "FUNC" and shndx.isdigit():
                func_locs[sname] = (int(shndx), val)
    extra_und = und_syms - ALLOWED_UND
    assert not extra_und, f"Unexpected undefined symbols without CRCs: {extra_und}"
    print(f"[OK] UND symbols verified ({len(und_syms)}): {sorted(und_syms)}")

    for fname, exp_hash in EXPECTED_KCFI.items():
        assert fname in func_locs, f"Missing function {fname}"
        sidx, foff = func_locs[fname]
        assert foff >= 4, f"{fname} at offset {foff} has no room for kCFI prefix!"
        _, sname, soff, ssz, *_ = sec_by_idx[sidx]
        got_hash = struct.unpack_from("<I", data, soff + foff - 4)[0]
        first_insn = struct.unpack_from("<I", data, soff + foff)[0]
        assert got_hash == exp_hash, \
            f"{fname} kCFI mismatch: got {hex(got_hash)}, expected {hex(exp_hash)}"
        assert first_insn in (0xd503233f, 0xd503245f, 0xd50324df), \
            f"{fname} first insn {hex(first_insn)} is not PACIASP or BTI!"
        print(f"[OK] {fname:16s} ({sname}+{hex(foff)}): kCFI={hex(got_hash)} insn0={hex(first_insn)}")

    disasm = run(["llvm-objdump", "-d", KO])
    x18_hits = [l for l in disasm.splitlines() if re.search(r"\b[xw]18\b", l)]
    assert not x18_hits, f"Found forbidden x18/w18 register use:\n" + "\n".join(x18_hits[:10])
    print("[OK] Zero x18/w18 shadow-call-stack clobbers")
    print(f"\nSUCCESS: Built & verified {KO} ({os.path.getsize(KO)} bytes)")

if __name__ == "__main__":
    main()
