#!/usr/bin/env python3
"""Generate ca/claude-code-unraid.png, the plugin's icon for Community Applications.

A plain terminal glyph (a prompt chevron and a cursor block) on a rounded dark
tile, drawn with a tiny built-in PNG encoder so that no imaging library is
needed. Not Anthropic's logo, not animated, 256x256 RGBA.

    python3 scripts/make-icon.py [OUT]
"""
import struct
import sys
import zlib

SIZE = 256
BG = (36, 41, 54)        # tile
FG = (255, 255, 255)     # glyph
ACCENT = (224, 122, 95)  # cursor block
RADIUS = 48


def rounded_tile(x, y):
    """Inside the rounded square?"""
    cx = min(max(x, RADIUS), SIZE - 1 - RADIUS)
    cy = min(max(y, RADIUS), SIZE - 1 - RADIUS)
    return (x - cx) ** 2 + (y - cy) ** 2 <= RADIUS ** 2


def chevron(x, y):
    """A '>' made of two thick diagonal strokes."""
    thickness = 18
    x0, y0 = 62, 84      # start of the upper stroke
    x1, y1 = 118, 128    # the tip
    y2 = 172             # end of the lower stroke
    # distance from point to segment, upper and lower
    for (ax, ay, bx, by) in ((x0, y0, x1, y1), (x1, y1, x0, y2)):
        vx, vy = bx - ax, by - ay
        wx, wy = x - ax, y - ay
        t = max(0.0, min(1.0, (vx * wx + vy * wy) / float(vx * vx + vy * vy)))
        dx, dy = ax + t * vx - x, ay + t * vy - y
        if dx * dx + dy * dy <= (thickness / 2.0) ** 2:
            return True
    return False


def cursor(x, y):
    return 140 <= x < 196 and 150 <= y < 174


def pixel(x, y):
    if not rounded_tile(x, y):
        return (0, 0, 0, 0)
    if chevron(x, y):
        return FG + (255,)
    if cursor(x, y):
        return ACCENT + (255,)
    return BG + (255,)


def png(width, height, rows):
    def chunk(tag, data):
        c = struct.pack('>I', len(data)) + tag + data
        return c + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF)
    raw = b''.join(b'\x00' + bytes(row) for row in rows)
    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw, 9))
            + chunk(b'IEND', b''))


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else 'ca/claude-code-unraid.png'
    rows = []
    for y in range(SIZE):
        row = []
        for x in range(SIZE):
            row.extend(pixel(x, y))
        rows.append(row)
    with open(out, 'wb') as f:
        f.write(png(SIZE, SIZE, rows))
    print(out)


if __name__ == '__main__':
    main()
