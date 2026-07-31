#!/usr/bin/env python3
"""Generate a simple solid-color RGBA PNG icon (pure stdlib, no PIL)."""
import struct, zlib, os

SIZE = 256
# Teal accent color (R, G, B, A)
COLOR = (56, 211, 159, 255)

def chunk(tag, data):
    c = struct.pack(">I", len(data)) + tag + data
    c += struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)
    return c

def make_png(path, size, color):
    r, g, b, a = color
    # Each scanline: filter byte (0) + RGBA pixels.
    row = b"\x00" + bytes([r, g, b, a]) * size
    raw = row * size
    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)  # 8-bit RGBA
    idat = zlib.compress(raw, 9)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", ihdr)
    png += chunk(b"IDAT", idat)
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)

if __name__ == "__main__":
    import sys
    here = os.path.dirname(os.path.abspath(__file__))
    size = int(sys.argv[1]) if len(sys.argv) > 1 else SIZE
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(here, "icons", "icon.png")
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    make_png(out, size, COLOR)
    print("wrote", out, os.path.getsize(out), "bytes")