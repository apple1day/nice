"""Make tiny index and sample resources for the >4 GiB picked-file decoder test."""

from pathlib import Path
import struct
import subprocess
import sys
import tempfile


SAMPLE_START = 1 << 32
CONTAINERS = {b"moov", b"trak", b"mdia", b"minf", b"stbl"}


def boxes(data):
    pos = 0
    while pos < len(data):
        size, kind = struct.unpack_from(">I4s", data, pos)
        if size < 8 or pos + size > len(data):
            raise ValueError("Unexpected box in the small ffmpeg input")
        yield pos, kind, data[pos + 8 : pos + size]
        pos += size


def box(kind, contents):
    return struct.pack(">I4s", 8 + len(contents), kind) + contents


def widen_offsets(kind, contents, old_start, old_end):
    if kind in CONTAINERS:
        contents = b"".join(
            widen_offsets(child, data, old_start, old_end)
            for _, child, data in boxes(contents)
        )
    elif kind == b"stco":
        count = struct.unpack_from(">I", contents, 4)[0]
        offsets = struct.unpack(f">{count}I", contents[8:])
        if not offsets or any(n < old_start or n >= old_end for n in offsets):
            raise ValueError("Unexpected chunk outside the input mdat")
        contents = contents[:8] + b"".join(
            struct.pack(">Q", SAMPLE_START + n - old_start) for n in offsets
        )
        kind = b"co64"
    return box(kind, contents)


def make_fixture(source):
    with tempfile.TemporaryDirectory() as folder:
        compact = Path(folder) / "indexed.mp4"
        # Give both outputs time to start and leave several keyframes for seeks.
        subprocess.run(
            ["ffmpeg", "-v", "error", "-stream_loop", "3", "-i", str(source),
             "-map", "0:v:0", "-map", "0:a:0", "-c", "copy", "-movflags", "+faststart",
             str(compact)], check=True,
        )
        write_sparse_parts(compact, source.with_name("co64"))


def write_sparse_parts(compact, prefix):
    atoms = list(boxes(compact.read_bytes()))
    [(mdat_pos, samples)] = [(pos, data) for pos, kind, data in atoms if kind == b"mdat"]
    [ftyp] = [data for _, kind, data in atoms if kind == b"ftyp"]
    [moov] = [data for _, kind, data in atoms if kind == b"moov"]
    old_start = mdat_pos + 8
    index = box(b"ftyp", ftyp) + widen_offsets(b"moov", moov, old_start, old_start + len(samples))
    # An extended-size mdat describes a hole followed by the original A/V data.
    # Its first sample is exactly at 4 GiB; subsequent chunks are above it.
    mdat_size = SAMPLE_START + len(samples) - len(index)
    index += struct.pack(">I4sQ", 1, b"mdat", mdat_size)
    prefix.with_name(prefix.name + "-index.bin").write_bytes(index)
    prefix.with_name(prefix.name + "-samples.bin").write_bytes(samples)


if __name__ == "__main__":
    if len(sys.argv) == 2:
        make_fixture(Path(sys.argv[1]))
    else:
        write_sparse_parts(Path(sys.argv[1]), Path(sys.argv[2]))
