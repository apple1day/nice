"""Validate a stream-copy hvc1 comparison for conventional single-track HEVC MP4."""
from contextlib import contextmanager
from itertools import zip_longest
from fractions import Fraction
from math import gcd
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


PARAMETERS = {32, 33, 34}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def unhex(dump):
    # ffprobe -show_data emits address, hexadecimal words, two spaces, ASCII.
    return bytes.fromhex("".join(line.split(": ", 1)[1].split("  ", 1)[0]
                                 for line in dump.splitlines() if line.strip()))


def unit_type(unit):
    require(len(unit) >= 2 and not unit[0] & 0x81 and unit[1] >> 3 == 0 and unit[1] & 7,
            "无效或多层 HEVC NAL；仅支持普通单层视频")
    return (unit[0] >> 1) & 63


def configuration(data, complete=False):
    require(len(data) >= 23 and data[0] == 1, "hvcC 配置信息不完整")
    nbytes = (data[21] & 3) + 1
    require(nbytes in (1, 2, 4), "不支持的 NAL 长度格式")
    normalized = bytearray(data)
    params = {}
    cursor = 23
    for _ in range(data[22]):
        require(cursor + 3 <= len(data), "hvcC 数组头越界")
        header = data[cursor]
        kind = header & 63
        count = int.from_bytes(data[cursor + 1:cursor + 3], "big")
        if kind in PARAMETERS:
            require(kind not in params and count == 1, "仅支持一套固定的 VPS、SPS 和 PPS")
            require(not complete or header & 0x80, "输出 hvcC 未声明参数集完整")
            normalized[cursor] |= 0x80
        cursor += 3
        for _ in range(count):
            require(cursor + 2 <= len(data), "hvcC 长度越界")
            length = int.from_bytes(data[cursor:cursor + 2], "big")
            cursor += 2
            end = cursor + length
            require(end <= len(data) and unit_type(data[cursor:end]) == kind, "hvcC 参数集无效")
            if kind in PARAMETERS:
                params[kind] = data[cursor:end]
            cursor = end
    require(cursor == len(data) and params.keys() == PARAMETERS, "hvcC 缺少静态 VPS、SPS 或 PPS")
    return nbytes, params, bytes(normalized)


def retained_units(packet, config, output=False):
    width, params, _ = config
    pos = 0
    while pos < len(packet):
        require(pos + width <= len(packet), "NAL 长度越界")
        length = int.from_bytes(packet[pos:pos + width], "big")
        pos += width
        end = pos + length
        require(end <= len(packet), "NAL 数据越界")
        unit = packet[pos:end]
        kind = unit_type(unit)
        if kind in PARAMETERS:
            require(not output and params[kind] == unit, "发现带内参数集变化或输出仍含带内参数集")
        else:
            yield unit
        pos = end


def probe(path):
    entries = "stream=index,codec_name,codec_type,codec_tag_string,extradata,width,height,pix_fmt,profile,level,color_range,color_space,color_transfer,color_primaries,chroma_location,sample_aspect_ratio,field_order,time_base,sample_rate,channels,channel_layout:stream_disposition:stream_tags:stream_side_data:format=format_name:format_tags:chapter"
    command = ["ffprobe", "-v", "error", "-show_data", "-show_entries", entries, "-of", "json", str(path)]
    return json.loads(subprocess.check_output(command))


def media(info, expected_tag):
    require("mp4" in info["format"]["format_name"].split(",") and not info.get("chapters"),
            "仅支持无章节的普通本地 MP4")
    streams = info["streams"]
    videos = [s for s in streams if s["codec_type"] == "video"]
    audio = [s for s in streams if s["codec_type"] == "audio" and s["codec_name"] == "aac"]
    require(len(videos) == 1 and len(audio) <= 1 and len(streams) == 1 + len(audio),
            "仅支持一条 HEVC 视频轨及可选的一条 AAC 音轨")
    v = videos[0]
    require(v["codec_name"] == "hevc" and v["codec_tag_string"] == expected_tag,
            "所选影片的视频编码或封装标签不匹配：" + expected_tag)
    return v["index"], configuration(unhex(v["extradata"]), complete=expected_tag == "hvc1")


def payload(file, pos, size):
    require(pos >= 0 and size > 0, "无效的本地样本位置")
    file.seek(pos)
    data = file.read(size)
    require(len(data) == size, "本地样本被截断")
    return data


@contextmanager
def packet_index(path, stream):
    entries = "packet=pts,dts,duration,flags,pos,size:packet_side_data"
    cmd = ["ffprobe", "-v", "error", "-select_streams", str(stream), "-show_packets",
           "-show_entries", entries, "-of", "compact=p=0:nk=0", str(path)]

    def records(lines):
        for line in lines:
            if not line.strip():
                continue
            fields = dict(x.split("=", 1) for x in line.strip().split("|") if "=" in x)
            for k, v in fields.items():
                if k.endswith("side_data_type"):
                    require(v == "Skip Samples", "发现动态解码配置、加密或不支持的样本附加信息：" + v)
            yield int(fields.pop("pos")), int(fields.pop("size")), fields

    with subprocess.Popen(cmd, stdout=subprocess.PIPE, text=True) as task:
        try:
            yield records(task.stdout)
            require(task.wait() == 0, "无法完整读取样本索引")
        finally:
            task.stdout.close()
            if task.poll() is None:
                task.kill()


def audit_source(path, config):
    # Seeking into an MP4 may depend on a configuration change earlier in it.
    with path.open("rb") as file, packet_index(path, "v:0") as packets:
        for pos, size, _ in packets:
            for _ in retained_units(payload(file, pos, size), config):
                pass


def check_metadata(before, after):
    # Container brands identify the muxer. Preserve all other exposed file tags
    # and all exposed per-track display, color, disposition and audio metadata.
    def tags(info):
        return {k: v for k, v in info["format"].get("tags", {}).items()
                if k not in ("major_brand", "minor_version", "compatible_brands", "encoder")}
    require(tags(before) == tags(after), "复制时文件元数据发生变化")
    def tracks(info):
        return [{k: v for k, v in s.items() if k != "codec_tag_string"
                 and not (k == "extradata" and s["codec_type"] == "video")} for s in info["streams"]]
    require(tracks(before) == tracks(after), "复制时音轨、画面排布、时间基或其他轨道信息发生变化")


def check_pair(src, dst):
    a, b = probe(src), probe(dst)
    vi, ca = media(a, "hev1")
    _, cb = media(b, "hvc1")
    require(ca == cb, "重封装改变了解码配置")
    check_metadata(a, b)
    with src.open("rb") as left, dst.open("rb") as right:
        for stream in a["streams"]:
            idx = stream["index"]
            count = 0
            with packet_index(src, idx) as aa, packet_index(dst, idx) as bb:
                for p, q in zip_longest(aa, bb):
                    require(p and q, "复制前后样本数量不一致")
                    require(p[2] == q[2], "样本时间戳、标记或附加信息发生变化")
                    if idx == vi and count == 0:
                        require("K" in p[2]["flags"], "文件未从关键帧开始")
                    x = payload(left, p[0], p[1])
                    y = payload(right, q[0], q[1])
                    if idx == vi:
                        source_units = tuple(retained_units(x, ca))
                        if count == 0:
                            require(any(16 <= unit_type(n) <= 21 for n in source_units),
                                    "首个视频样本未含 HEVC 随机访问图像")
                        require(source_units == tuple(retained_units(y, cb, output=True)),
                                "视频压缩数据发生变化")
                    else:
                        require(x == y, "音频压缩数据发生变化")
                    count += 1
            require(count, "缺少音频或视频样本")


def fingerprint(path):
    st = path.stat()
    return st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns


def publish(files, destination):
    # Reserve all target names exclusively before publishing. Unlike hard links,
    # rename on the same volume works on local exFAT destinations as well.
    reserved = []
    try:
        for src in files:
            target = destination / src.name
            fd = os.open(target, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            reserved.append(target)
            os.close(fd)
        for src, target in zip(files, reserved):
            os.replace(src, target)
    except BaseException:
        for target in reserved:
            target.unlink(missing_ok=True)
        raise


def make_sample(path, start, destination):
    original_stat = fingerprint(path)
    base = probe(path)
    _, config = media(base, "hev1")
    print("正在核对压缩数据与时间戳，全程无需重新编码…", flush=True)
    common = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-n"]
    # MP4's default 1000 Hz movie clock can round the final AAC packet's
    # duration. Use a common integral clock, then verify native stream ticks.
    scale = 1
    for stream in base["streams"]:
        ticks = Fraction(stream["time_base"]).denominator
        scale = scale // gcd(scale, ticks) * ticks
    require(0 < scale <= 2147483647, "这些轨道没有可用的公共电影时间基")
    copy = ["-map", "0", "-map_metadata", "0", "-c", "copy", "-movie_timescale", str(scale),
            "-movflags", "+faststart+use_metadata_tags"]
    with tempfile.TemporaryDirectory(dir=destination) as folder:
        full = start == "full"
        reference = path
        if not full:
            audit_source(path, config)
            reference = Path(folder, "original-codec.mp4")
            subprocess.run(common + ["-ss", start, "-i", str(path), "-t", "30"] + copy + [str(reference)], check=True)
            clipped = probe(reference)
            check_metadata(base, clipped)
            require(media(clipped, "hev1")[1] == config, "截取片段的解码配置发生变化")
        result = Path(folder, "hvc1-full.mp4" if full else "hvc1-sample.mp4")
        subprocess.run(common + ["-copyts", "-i", str(reference)] + copy +
                       ["-bsf:v:0", "filter_units=remove_types=32|33|34", "-tag:v:0", "hvc1",
                        "-avoid_negative_ts", "disabled", str(result)], check=True)
        check_pair(reference, result)
        require(fingerprint(path) == original_stat, "处理期间原文件已改变")
        publish([result] if full else [reference, result], destination)
        if not full:
            print(f"原编码对照：{destination / reference.name}")
        print(f"同分辨率 hvc1：{destination / result.name}")


if __name__ == "__main__":
    try:
        make_sample(Path(sys.argv[1]).resolve(), sys.argv[2], Path(sys.argv[3]).resolve())
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        sys.exit(f"未能生成已校验的 hvc1 对照。{exc}")
