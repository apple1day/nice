import contextlib
import io
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import hevc_sample as hevc


def unit(kind, rbsp):
    return bytes([kind << 1, 1]) + rbsp


def hvcc():
    record = bytearray(23)
    record[0], record[21], record[22] = 1, 3, 3
    for n in sorted(hevc.PARAMETERS):
        record.extend(bytes([n, 0, 1, 0, 4]) + unit(n, b"ab"))
    return bytes(record)


def packet(*units):
    return b"".join(len(x).to_bytes(4, "big") + x for x in units)


class HVC1UnitTests(unittest.TestCase):
    def test_complete_configuration_and_identical_repeats(self):
        raw = hvcc()
        source = hevc.configuration(raw)
        normalized = source[2]
        self.assertEqual(hevc.configuration(normalized, complete=True), source)
        with self.assertRaises(ValueError):
            hevc.configuration(raw, complete=True)
        picture, sei = unit(19, b"a"), unit(39, b"b")
        data = packet(unit(32, b"ab"), sei, unit(34, b"ab"), picture)
        self.assertEqual(list(hevc.retained_units(data, source)), [sei, picture])
        with self.assertRaises(ValueError):
            list(hevc.retained_units(data, source, output=True))

    def test_declines_changing_and_truncated_data(self):
        config = hevc.configuration(hvcc())
        for data in (packet(unit(33, b"cd")), b"\0", b"\0\0\0\x08ab", packet(b""), packet(b"\x42\x00")):
            with self.subTest(data=data), self.assertRaises(ValueError):
                list(hevc.retained_units(data, config))
        with self.assertRaises(ValueError):
            hevc.configuration(hvcc()[:-1])

    def test_publish_refuses_existing_second_file_and_cleans_reservations(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            out = root / "out"
            out.mkdir()
            files = [root / "a", root / "b"]
            for path in files:
                path.write_bytes(b"new")
            (out / "b").write_bytes(b"keep")
            with self.assertRaises(FileExistsError):
                hevc.publish(files, out)
            self.assertFalse((out / "a").exists())
            self.assertEqual((out / "b").read_bytes(), b"keep")


@unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "needs FFmpeg")
class HVC1FileTests(unittest.TestCase):
    def test_timed_pair_full_copy_and_changed_parameter_rejection(self):
        with tempfile.TemporaryDirectory() as folder, contextlib.redirect_stdout(io.StringIO()):
            root = Path(folder)
            source = root / "source.mp4"
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=s=128x64:r=12",
                            "-f", "lavfi", "-i", "sine=frequency=441:sample_rate=48000",
                            "-t", "2", "-c:v", "libx265", "-preset", "ultrafast", "-x265-params",
                            "repeat-headers=1:keyint=12:bframes=2:pools=1:log-level=error",
                            "-tag:v", "hev1", "-c:a", "aac", "-metadata", "title=两眼片段",
                            "-metadata:s:a", "language=zho", str(source)], check=True)
            for start, name in [("0.5", "hvc1-sample.mp4"), ("full", "hvc1-full.mp4")]:
                out = root / start
                out.mkdir()
                hevc.make_sample(source, start, out)
                reference = source if start == "full" else out / "original-codec.mp4"
                hevc.check_pair(reference, out / name)
            # Corrupt only a repeated in-band parameter. hvcC is still intact;
            # the comparison must refuse to strip the now-different NAL.
            _, config = hevc.media(hevc.probe(source), "hev1")
            sps = config[1][33]
            with hevc.packet_index(source, "v:0") as packets, source.open("r+b") as f:
                pos = None
                for off, size, _ in packets:
                    if pos is None:
                        part = hevc.payload(f, off, size)
                        i = part.find(sps)
                        if i >= 0:
                            pos = off + i + len(sps) - 1
                self.assertIsNotNone(pos)
                f.seek(pos)
                byte = f.read(1)[0]
                f.seek(pos)
                f.write(bytes([byte ^ 1]))
            bad = root / "bad"
            bad.mkdir()
            with self.assertRaises(ValueError):
                hevc.make_sample(source, "0", bad)
            self.assertFalse(list(bad.iterdir()))


if __name__ == "__main__":
    unittest.main()
