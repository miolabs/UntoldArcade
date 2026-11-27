#!/usr/bin/env python3
"""Minimal reader for .untold animation files (file type 5). Read-only inventory."""
import struct, sys, os, json
import numpy as np

def read(path):
    d = open(path, 'rb').read()
    assert d[:8] == b"UNTOLD\x00\x00", path
    version, ftype = struct.unpack_from("<II", d, 8)
    # find chunk_count: header is 204 bytes; chunk count field location: scan for plausible
    chunks = {}
    # header layout: magic(8) version(4) fileType(4) flags?(4) headerSize(4) chunkCount(4)
    hdr_flags, hdr_size, chunk_count = struct.unpack_from("<III", d, 16)
    off = hdr_size
    for i in range(chunk_count):
        ctype, comp, foff, csize, usize, ecount, _ = struct.unpack_from("<IIQQQII", d, off + 40 * i)
        chunks[ctype] = (foff, csize, ecount, comp)
    def cstr(o):
        s0 = chunks[1][0] + o
        e = d.index(b"\x00", s0)
        return d[s0:e].decode()
    clips = []
    coff, _, ccount, _ = chunks[12]
    choff, _, chcount, _ = chunks[13]
    toff, _, tcount, _ = chunks[14]
    roff, _, rcount, _ = chunks[15]
    T = np.frombuffer(d, dtype="<f4", count=tcount * 5, offset=toff).reshape(-1, 5) if tcount else np.zeros((0, 5), np.float32)
    R = np.frombuffer(d, dtype="<f4", count=rcount * 5, offset=roff).reshape(-1, 5) if rcount else np.zeros((0, 5), np.float32)
    for i in range(ccount):
        name_off, duration, first, count, flags, _, _ = struct.unpack_from("<IfIIIII", d, coff + 28 * i)
        chans = []
        for j in range(first, first + count):
            jp, ft, tc, fr, rc, fl, _ = struct.unpack_from("<IIIIIII", d, choff + 28 * j)
            chans.append(dict(joint=cstr(jp), t=T[ft:ft + tc], r=R[fr:fr + rc]))
        clips.append(dict(name=cstr(name_off), duration=duration, channels=chans))
    return dict(version=version, file_type=ftype, clips=clips)

if __name__ == "__main__":
    for p in sys.argv[1:]:
        f = read(p)
        for c in f["clips"]:
            rc = [len(ch["r"]) for ch in c["channels"]]
            tc = [len(ch["t"]) for ch in c["channels"]]
            # frame rate from rotation key times of the densest channel
            ch = max(c["channels"], key=lambda ch: len(ch["r"]))
            times = ch["r"][:, 0]
            dt = np.diff(times)
            fps = 1.0 / np.median(dt) if len(dt) else 0
            print(json.dumps(dict(file=os.path.basename(p), clip=c["name"], duration=round(float(c["duration"]), 4),
                                  channels=len(c["channels"]), rot_keys_max=max(rc), rot_keys_min=min(rc),
                                  tr_keys_max=max(tc), tr_keys_min=min(tc), fps=round(float(fps), 3),
                                  t0=round(float(times[0]), 4), t_last=round(float(times[-1]), 4))))
