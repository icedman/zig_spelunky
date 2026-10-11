#!/usr/bin/env python3
"""Prepare the Playdate Source/ tree from the packed game assets.

    python3 tools/playdate_assets.py [--assets build/assets]
        [--data reference/SpelunkyClassicHD/datafiles] [--out playdate/Source]
        [--force] [--music-pcm] [--jobs N]

Input is what `make gen` writes (tools/asset_packer.py):
    build/assets/sprites/<name>/<i>.png    sprite frames (RGBA)
    build/assets/sounds/<name>             sounds, no extension (WAV or Ogg Vorbis)

Output (compiled by pdc into the .pdx; see src/host/playdate/main_playdate.c):
    Source/assets/sprites/<name>/<i>.png   1-bit frames: levels + ordered dither,
                                           alpha cut to fully opaque / transparent
    Source/assets/sounds/<name>.wav        effects (PCM WAV; loaded into memory)
    Source/assets/music/<name>.wav         music (mono 22.05 kHz IMA ADPCM; streamed)
    Source/data/...                        the game's datafiles (working_directory),
                                           without fonts / html; PNGs made 1-bit
    Source/fonts/<font>                    a Playdate font copied from the SDK
    Source/launcher/card.png, icon.png     generated when missing

The Playdate screen is 1-bit, and pdc only thresholds colour images, which turns
most of Spelunky's dark palette solid black. Each sprite is therefore remapped
with per-category levels (black point, white point, gamma), as in
reference/tools_assets/adjust_exposure.sh, then either thresholded (small,
readable sprites: player, HUD, font) or dithered with a 4x4 Bayer matrix
(`magick -ordered-dither o4x4`: terrain, backgrounds, items, enemies).
Tune PROFILES below; the first matching pattern wins.

Work is incremental: outputs newer than their input and this script are kept.
Needs Pillow and numpy; ffmpeg for sound conversion.
"""

import argparse
import concurrent.futures
import os
import re
import shutil
import subprocess
import sys
import wave

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT_MTIME = os.path.getmtime(os.path.abspath(__file__))

# (category, sprite-name regex, levels). black / white are input luminance points
# (0..1) mapped to black / white; gamma < 1 darkens the mid-tones, > 1 lightens.
# auto = A (instead of black / white): per image, the 98th-percentile luminance
# maps to grey level A - backgrounds range from near-black caves to bright skies,
# and must stay darker than the terrain in front of them.
PROFILES = [
    ("ui", r"^(sFont|sMenu|s\w*Button|\w*Icon|sHeart|sDollarSign|sTimer|sBox|sPage|"
           r"sRedArrow|sNew$|sLvl|sSlider|sHintPoint|sItemGet|sBombsGet|sRopeGet|sTitle$|Touch)",
     dict(black=0.05, white=0.5, gamma=1.0, dither=False)),
    ("player", r"^s(Stand|Run|Jump|Fall|Duck|Crawl|Hang|Climb|Look|Push|Throw|Attack|Whoa|"
               r"StunL|DieL|PExit|PKiss|Whip|Damsel|Tunnel)",
     dict(black=0.1, white=0.7, gamma=1.0, dither=False)),
    ("background", r"^(bg|background|s\w*BG|sBG)",
     dict(auto=0.5, gamma=1.0, dither=True)),
    ("terrain", r"^s(Brick|Cave|Dark|Lush|Ice|Temple|GTemple|Block|Desert|Alien(Floor|Top)|"
                r"MetalBlock|GoldBlock|SkullBlock|ThinIce|Lava|Water|Magma|Ladder|Vine|Tree|"
                r"Leaves|Spikes|Moai|Sac|Altar|Barrier|Door|Entrance|Exit|EndWall|EndPlat|"
                r"Olmec|Kali|Chain|PalmTree|Shrub|Web)",
     dict(black=0.025, white=0.25, gamma=1.0, dither=True)),
    ("default", r"", dict(black=0.05, white=0.5, gamma=1.0, dither=True)),
]
_PROFILE_RE = [(name, re.compile(rx), lv) for name, rx, lv in PROFILES]

# 4x4 Bayer thresholds in (0, 1), like ImageMagick's o4x4.
_BAYER4 = (np.array([[0, 8, 2, 10],
                     [12, 4, 14, 6],
                     [3, 11, 1, 9],
                     [15, 7, 13, 5]], dtype=np.float32) + 0.5) / 16.0

PD_FONT = ("Nontendo", "Nontendo-Bold")  # SDK Resources/Fonts/<dir>/<name>.fnt
CARD_SIZE = (350, 155)
ICON_SIZE = (32, 32)


def profile_for(name):
    for category, rx, levels in _PROFILE_RE:
        if rx.search(name):
            return category, levels
    raise AssertionError("the default profile matches everything")


def up_to_date(src, dst, force):
    if force or not os.path.exists(dst):
        return False
    mtime = os.path.getmtime(dst)
    return mtime >= os.path.getmtime(src) and mtime >= SCRIPT_MTIME


def to_1bit(img, black=0.0, white=1.0, gamma=1.0, dither=True, auto=None):
    """RGBA image -> RGBA image of opaque black / opaque white / transparent pixels."""
    rgba = np.asarray(img.convert("RGBA"), dtype=np.float32) / 255.0
    lum = rgba[..., 0] * 0.299 + rgba[..., 1] * 0.587 + rgba[..., 2] * 0.114
    if auto is not None:
        opaque = lum[rgba[..., 3] >= 0.5]
        top = float(np.percentile(opaque, 98)) if opaque.size else 1.0
        black, white = 0.0, max(top, 1e-3) / auto
    lum = np.clip((lum - black) / max(white - black, 1e-6), 0.0, 1.0)
    if gamma != 1.0:
        lum = lum ** (1.0 / gamma)
    if dither:
        h, w = lum.shape
        thresh = np.tile(_BAYER4, (h // 4 + 1, w // 4 + 1))[:h, :w]
        on = lum > thresh
    else:
        on = lum >= 0.5
    out = np.zeros(rgba.shape, dtype=np.uint8)
    out[..., :3] = np.where(on, 255, 0)[..., None]
    out[..., 3] = np.where(rgba[..., 3] >= 0.5, 255, 0)
    out[out[..., 3] == 0] = 0
    return Image.fromarray(out, "RGBA")


def convert_image(job):
    if len(job) == 5:
        frame_srcs, dst, levels, w, h = job
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        table = Image.new("RGBA", (w * len(frame_srcs), h))
        for i, src in enumerate(frame_srcs):
            with Image.open(src) as img:
                f1bit = to_1bit(img, **levels)
                table.paste(f1bit, (i * w, 0))
        table.save(dst)
        return dst

    src, dst, levels = job
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with Image.open(src) as img:
        to_1bit(img, **levels).save(dst)
    return dst


# ----------------------------------------------------------------------------- sprites

def sprite_jobs(assets, out, force):
    src_root = os.path.join(assets, "sprites")
    dst_root = os.path.join(out, "assets", "sprites")
    os.makedirs(dst_root, exist_ok=True)

    # Clean up obsolete sprite subdirectories
    for item in os.listdir(dst_root):
        item_path = os.path.join(dst_root, item)
        if os.path.isdir(item_path):
            shutil.rmtree(item_path)

    jobs, counts = [], {}
    for name in sorted(os.listdir(src_root)):
        sdir = os.path.join(src_root, name)
        if not os.path.isdir(sdir):
            continue
        category, levels = profile_for(name)
        counts[category] = counts.get(category, 0) + 1
        frame_files = [f for f in os.listdir(sdir) if f.endswith(".png")]
        if not frame_files:
            continue
        frame_files.sort(key=lambda x: int(os.path.splitext(x)[0]) if os.path.splitext(x)[0].isdigit() else x)

        if len(frame_files) > 1:
            # Multi-frame sprite: horizontal strip bitmap table
            first_src = os.path.join(sdir, frame_files[0])
            with Image.open(first_src) as img0:
                w, h = img0.size
            table_dst = os.path.join(dst_root, f"{name}-table-{w}-{h}.png")
            need_table = force or not os.path.exists(table_dst)
            if not need_table:
                dst_mtime = os.path.getmtime(table_dst)
                if dst_mtime < SCRIPT_MTIME:
                    need_table = True
                else:
                    for f in frame_files:
                        if dst_mtime < os.path.getmtime(os.path.join(sdir, f)):
                            need_table = True
                            break
            if need_table:
                frame_srcs = [os.path.join(sdir, f) for f in frame_files]
                jobs.append((frame_srcs, table_dst, levels, w, h))
        else:
            # Single-frame sprite: flat image
            src = os.path.join(sdir, frame_files[0])
            flat_dst = os.path.join(dst_root, f"{name}.png")
            if not up_to_date(src, flat_dst, force):
                jobs.append((src, flat_dst, levels))

    return jobs, counts


# ----------------------------------------------------------------------------- sounds

def sniff(path):
    with open(path, "rb") as f:
        head = f.read(12)
    if head[:4] == b"RIFF" and head[8:12] == b"WAVE":
        return "wav"
    if head[:4] == b"OggS":
        return "ogg"
    if head[:3] == b"ID3" or head[:2] in (b"\xff\xfb", b"\xff\xf3", b"\xff\xf2"):
        return "mp3"
    return "unknown"


def wav_is_playdate_ready(path):
    """Uncompressed 8/16-bit PCM, mono or stereo: the formats pdc takes as is."""
    try:
        with wave.open(path, "rb") as w:
            return (w.getcomptype() == "NONE" and w.getsampwidth() in (1, 2)
                    and w.getnchannels() in (1, 2) and w.getframerate() <= 48000)
    except (wave.Error, EOFError):
        return False


def is_music(name, kind):
    # The packer keeps the project's files: music is the Ogg streams (mTitle, mCave ...).
    return kind != "wav" or re.match(r"^m[A-Z]", name) is not None


def ffmpeg(src, dst, music, music_pcm):
    cmd = ["ffmpeg", "-v", "error", "-y", "-i", src, "-map_metadata", "-1", "-ac", "1"]
    if music:
        cmd += ["-ar", "22050"]
        cmd += ["-c:a", "pcm_s16le"] if music_pcm else ["-c:a", "adpcm_ima_wav"]
    else:
        cmd += ["-c:a", "pcm_s16le"]
    cmd.append(dst)
    subprocess.run(cmd, check=True)


def build_sounds(assets, out, force, music_pcm):
    src_root = os.path.join(assets, "sounds")
    have_ffmpeg = shutil.which("ffmpeg") is not None
    done = copied = converted = 0
    missing = []
    for name in sorted(os.listdir(src_root)):
        src = os.path.join(src_root, name)
        if not os.path.isfile(src):
            continue
        stem = os.path.splitext(name)[0]
        kind = sniff(src)
        music = is_music(stem, kind)
        dst = os.path.join(out, "assets", "music" if music else "sounds", stem + ".wav")
        stale = os.path.join(out, "assets", "sounds" if music else "music", stem + ".wav")
        if os.path.exists(stale):
            os.remove(stale)
        done += 1
        if up_to_date(src, dst, force):
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if kind == "wav" and not music and wav_is_playdate_ready(src):
            shutil.copyfile(src, dst)
            copied += 1
        elif have_ffmpeg:
            ffmpeg(src, dst, music, music_pcm)
            converted += 1
        else:
            missing.append(name)
    if missing:
        sys.exit("playdate_assets: ffmpeg is needed to convert %d sounds (%s ...)"
                 % (len(missing), ", ".join(missing[:5])))
    print("sounds: %d (%d copied, %d converted, rest up to date)" % (done, copied, converted))


# ----------------------------------------------------------------------------- datafiles

DATA_SKIP_EXT = {".ttf", ".woff", ".woff2", ".html", ".htm"}


def data_jobs(data, out, force):
    """Copies the datafiles to Source/data; returns the PNG conversion jobs."""
    jobs, copied = [], 0
    if not data or not os.path.isdir(data):
        print("data: %s not found, skipped" % data)
        return jobs
    dst_root = os.path.join(out, "data")
    for root, _dirs, files in os.walk(data):
        rel = os.path.relpath(root, data)
        for f in files:
            ext = os.path.splitext(f)[1].lower()
            if ext in DATA_SKIP_EXT or (rel == "." and f == "icon.png"):
                continue
            src = os.path.join(root, f)
            dst = os.path.normpath(os.path.join(dst_root, rel, f))
            if up_to_date(src, dst, force):
                continue
            if ext == ".png":
                jobs.append((src, dst, profile_for("")[1]))
            else:
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copyfile(src, dst)
                copied += 1
    print("data: %d files copied, %d images queued" % (copied, len(jobs)))
    return jobs


# ----------------------------------------------------------------------------- font, launcher

def sdk_path():
    sdk = os.environ.get("PLAYDATE_SDK_PATH")
    if sdk:
        return sdk
    cfg = os.path.expanduser("~/.Playdate/config")
    if os.path.exists(cfg):
        with open(cfg) as f:
            for line in f:
                if line.strip().startswith("SDKRoot"):
                    return line.split(None, 1)[1].strip()
    return None


def copy_font(out):
    sdk = sdk_path()
    folder, name = PD_FONT
    src_dir = os.path.join(sdk, "Resources", "Fonts", folder) if sdk else None
    if not src_dir or not os.path.isdir(src_dir):
        print("font: Playdate SDK fonts not found; the system font will be used")
        return
    dst_dir = os.path.join(out, "fonts")
    os.makedirs(dst_dir, exist_ok=True)
    n = 0
    for f in os.listdir(src_dir):
        if f == name + ".fnt" or f.startswith(name + "-table-"):
            shutil.copyfile(os.path.join(src_dir, f), os.path.join(dst_dir, f))
            n += 1
    print("font: %s (%d files)" % (name, n))


def fit(img, size):
    """Scales `img` (nearest neighbour, integer factor when possible) onto a black canvas."""
    w, h = img.size
    s = min(size[0] / w, size[1] / h)
    if s >= 1:
        s = int(s)
    img = img.resize((max(1, int(w * s)), max(1, int(h * s))), Image.NEAREST)
    canvas = Image.new("RGBA", size, (0, 0, 0, 255))
    canvas.paste(img, ((size[0] - img.width) // 2, (size[1] - img.height) // 2), img)
    return canvas


def build_launcher(assets, data, out, force):
    ldir = os.path.join(out, "launcher")
    os.makedirs(ldir, exist_ok=True)
    card = os.path.join(ldir, "card.png")
    icon = os.path.join(ldir, "icon.png")
    if force or not os.path.exists(card):
        shot = os.path.join(ROOT, "build", "host_title.bmp")  # make test-host
        if os.path.exists(shot):
            with Image.open(shot) as im:
                im = im.convert("RGBA")
                crop_h = int(im.width * CARD_SIZE[1] / CARD_SIZE[0])
                top = (im.height - crop_h) // 2
                src = im.crop((0, top, im.width, top + crop_h)).resize(CARD_SIZE, Image.LANCZOS)
        else:
            with Image.open(os.path.join(assets, "sprites", "sTitle", "0.png")) as im:
                src = fit(im.convert("RGBA"), CARD_SIZE)
        to_1bit(src, black=0.0, white=0.6, gamma=1.0, dither=True).save(card)
        print("launcher: wrote", card)
    if force or not os.path.exists(icon):
        src_icon = os.path.join(data, "icon.png") if data else ""
        if os.path.exists(src_icon):
            with Image.open(src_icon) as im:
                src = im.convert("RGBA").resize(ICON_SIZE, Image.LANCZOS)
            to_1bit(src, black=0.05, white=0.5, gamma=1.0, dither=False).save(icon)
            print("launcher: wrote", icon)


# ----------------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--assets", default=os.path.join(ROOT, "build", "assets"))
    ap.add_argument("--data", default=os.path.join(ROOT, "reference", "SpelunkyClassicHD", "datafiles"))
    ap.add_argument("--out", default=os.path.join(ROOT, "playdate", "Source"))
    ap.add_argument("--force", action="store_true", help="rebuild everything")
    ap.add_argument("--music-pcm", action="store_true",
                    help="16-bit PCM music instead of IMA ADPCM (4x larger)")
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 1)
    args = ap.parse_args()

    if not os.path.isdir(os.path.join(args.assets, "sprites")):
        sys.exit("playdate_assets: %s/sprites not found - run `make gen` first" % args.assets)

    jobs, counts = sprite_jobs(args.assets, args.out, args.force)
    print("sprites: %s" % ", ".join("%s %d" % kv for kv in sorted(counts.items())))
    jobs += data_jobs(args.data, args.out, args.force)
    if jobs:
        print("images: converting %d frames" % len(jobs))
        if args.jobs > 1 and len(jobs) > 64:
            with concurrent.futures.ProcessPoolExecutor(max_workers=args.jobs) as pool:
                list(pool.map(convert_image, jobs, chunksize=32))
        else:
            for job in jobs:
                convert_image(job)
    else:
        print("images: up to date")

    build_sounds(args.assets, args.out, args.force, args.music_pcm)
    copy_font(args.out)
    build_launcher(args.assets, args.data, args.out, args.force)


if __name__ == "__main__":
    main()
