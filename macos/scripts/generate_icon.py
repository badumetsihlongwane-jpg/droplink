#!/usr/bin/env python3
"""
Generates a modern macOS squircle AppIcon.icns for DropLink using zero external packages.
Writes RGBA PNGs via Python stdlib (zlib + struct) and packs via macOS `iconutil`.
"""
import math
import os
import shutil
import struct
import subprocess
import sys
import zlib


def write_png(path, width, height, rgba_bytes):
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    raw = bytearray()
    stride = width * 4
    for y in range(height):
        raw.append(0)
        raw.extend(rgba_bytes[y * stride : (y + 1) * stride])

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(bytes(raw), 6)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def render_icon(size):
    buf = bytearray(size * size * 4)
    margin = size * 0.09
    inner = size - 2 * margin
    radius = inner * 0.225
    cx0, cy0 = margin, margin
    cx1, cy1 = size - margin, size - margin

    def dist_rounded_rect(x, y):
        qx = max(cx0 + radius - x, 0.0, x - (cx1 - radius))
        qy = max(cy0 + radius - y, 0.0, y - (cy1 - radius))
        return math.hypot(qx, qy) - radius

    def point_in_arrow(nx, ny):
        # Normalized coords in [-1, 1] inside icon
        # Top right-pointing arrow (y around -0.22)
        if -0.45 <= nx <= 0.20 and -0.30 <= ny <= -0.14:
            return True
        if 0.14 <= nx <= 0.56 and abs(ny + 0.22) <= (0.56 - nx) * 0.65:
            return True
        # Bottom left-pointing arrow (y around +0.22)
        if -0.20 <= nx <= 0.45 and 0.14 <= ny <= 0.30:
            return True
        if -0.56 <= nx <= -0.14 and abs(ny - 0.22) <= (nx + 0.56) * 0.65:
            return True
        return False

    for y in range(size):
        ny = (y - size / 2.0) / (inner / 2.0)
        for x in range(size):
            d = dist_rounded_rect(x + 0.5, y + 0.5)
            alpha = max(0.0, min(1.0, 0.5 - d))
            if alpha <= 0.0:
                continue

            t = ((x - cx0) + (y - cy0)) / (2.0 * inner)
            t = max(0.0, min(1.0, t))
            # Vibrant macOS Blue (#2563EB) -> Indigo (#4F46E5) -> Deep Violet (#4338CA)
            r = 37 + (79 - 37) * t
            g = 99 + (70 - 99) * t
            b = 235 + (229 - 235) * t

            # Subtle top glossy highlight
            hl = max(0.0, 1.0 - (y - cy0) / (inner * 0.45)) * 24.0
            r = min(255.0, r + hl)
            g = min(255.0, g + hl)
            b = min(255.0, b + hl * 0.6)

            nx = (x - size / 2.0) / (inner / 2.0)
            if point_in_arrow(nx, ny):
                r, g, b = 255.0, 255.0, 255.0

            idx = (y * size + x) * 4
            buf[idx] = int(r)
            buf[idx + 1] = int(g)
            buf[idx + 2] = int(b)
            buf[idx + 3] = int(alpha * 255)
    return buf


def main():
    if len(sys.argv) != 2:
        print("Usage: generate_icon.py <output.icns>")
        sys.exit(1)
    out_icns = sys.argv[1]
    iconset_dir = out_icns.replace(".icns", ".iconset")
    if os.path.exists(iconset_dir):
        shutil.rmtree(iconset_dir)
    os.makedirs(iconset_dir, exist_ok=True)

    # Render base high-res 512px icon and scale via macOS sips for speed & crispness
    base_png = os.path.join(iconset_dir, "icon_512x512.png")
    write_png(base_png, 512, 512, render_icon(512))

    sizes = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]
    for name, px in sizes:
        target = os.path.join(iconset_dir, name)
        subprocess.run(["sips", "-z", str(px), str(px), base_png, "--out", target], check=True, stdout=subprocess.DEVNULL)

    subprocess.run(["iconutil", "-c", "icns", iconset_dir, "-o", out_icns], check=True)
    shutil.rmtree(iconset_dir)
    print(f"Generated {out_icns}")


if __name__ == "__main__":
    main()
