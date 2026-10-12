#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 1024x1024 的 App 图标（纯文本脚本，无外部资源）。

优先用 Pillow 画得细一点；没有 Pillow 就退化到纯标准库（zlib + struct）的
逐像素实现，保证 CI 上「一定有图标可用」，不会因为缺依赖让构建失败。

用法：python3 tools/make_appicon.py [输出目录]
默认输出到 AIHOT/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
"""

import os
import struct
import sys
import zlib

SIZE = 1024

# 站点色系：近黑底 + 热度橙
BG_TOP = (18, 18, 21)
BG_BOTTOM = (10, 10, 12)
ORANGE = (255, 106, 43)
ORANGE_DIM = (196, 74, 26)
WHITE = (242, 242, 243)


def _blend(dst, src, alpha):
    return tuple(int(round(d * (1 - alpha) + s * alpha)) for d, s in zip(dst, src))


def _rounded_rect_alpha(x, y, x0, y0, x1, y1, r):
    """点 (x,y) 在圆角矩形内的覆盖率，1.0 表示完全在内。"""
    cx = min(max(x, x0 + r), x1 - r)
    cy = min(max(y, y0 + r), y1 - r)
    dx = x - cx
    dy = y - cy
    dist = (dx * dx + dy * dy) ** 0.5
    if dist <= r - 1:
        return 1.0
    if dist >= r + 1:
        # 可能落在矩形的直边区域
        if x0 <= x <= x1 and y0 <= y <= y1:
            return 1.0
        return 0.0
    return max(0.0, min(1.0, (r + 1 - dist) / 2.0))


def _pixel(x, y):
    """返回 (r, g, b)：垂直渐变背景 + 三根递增柱状条 + 一个热度圆点。"""
    t = y / float(SIZE - 1)
    color = tuple(int(round(a + (b - a) * t)) for a, b in zip(BG_TOP, BG_BOTTOM))

    # 柱状条（表达「榜单 / 排名上升」）
    bar_w = 132.0
    gap = 74.0
    total = bar_w * 3 + gap * 2
    left = (SIZE - total) / 2.0
    base_y = 748.0
    heights = (212.0, 330.0, 448.0)
    radius = 34.0

    for i, h in enumerate(heights):
        x0 = left + i * (bar_w + gap)
        x1 = x0 + bar_w
        y0 = base_y - h
        y1 = base_y
        a = _rounded_rect_alpha(x, y, x0, y0, x1, y1, radius)
        if a > 0:
            tone = ORANGE if i == 2 else ORANGE_DIM
            color = _blend(color, tone, a * (1.0 if i == 2 else 0.85))

    # 顶部热度圆点
    dot_r = 86.0
    dot_cx = SIZE / 2.0
    dot_cy = 232.0
    d = ((x - dot_cx) ** 2 + (y - dot_cy) ** 2) ** 0.5
    if d <= dot_r - 1:
        color = _blend(color, WHITE, 0.92)
    elif d < dot_r + 1:
        color = _blend(color, WHITE, 0.92 * max(0.0, (dot_r + 1 - d) / 2.0))

    return color


def _render_pixels():
    rows = []
    for y in range(SIZE):
        row = bytearray()
        row.append(0)  # PNG filter type 0
        for x in range(SIZE):
            r, g, b = _pixel(x, y)
            row += bytes((r & 0xFF, g & 0xFF, b & 0xFF))
        rows.append(bytes(row))
    return b"".join(rows)


def _png_bytes(raw):
    def chunk(tag, data):
        payload = tag + data
        return (
            struct.pack(">I", len(data))
            + payload
            + struct.pack(">I", zlib.crc32(payload) & 0xFFFFFFFF)
        )

    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)  # 8bit truecolor RGB
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def write_stdlib(path):
    with open(path, "wb") as fh:
        fh.write(_png_bytes(_render_pixels()))


def write_pillow(path):
    from PIL import Image, ImageDraw  # noqa: WPS433

    img = Image.new("RGB", (SIZE, SIZE), BG_BOTTOM)
    draw = ImageDraw.Draw(img)
    for y in range(SIZE):
        t = y / float(SIZE - 1)
        draw.line(
            [(0, y), (SIZE, y)],
            fill=tuple(int(round(a + (b - a) * t)) for a, b in zip(BG_TOP, BG_BOTTOM)),
        )
    bar_w, gap, base_y = 132, 74, 748
    total = bar_w * 3 + gap * 2
    left = (SIZE - total) // 2
    for i, h in enumerate((212, 330, 448)):
        x0 = left + i * (bar_w + gap)
        draw.rounded_rectangle(
            [x0, base_y - h, x0 + bar_w, base_y],
            radius=34,
            fill=ORANGE if i == 2 else ORANGE_DIM,
        )
    draw.ellipse([SIZE / 2 - 86, 232 - 86, SIZE / 2 + 86, 232 + 86], fill=WHITE)
    img.save(path, "PNG")


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        "AIHOT", "Assets.xcassets", "AppIcon.appiconset"
    )
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "AppIcon-1024.png")
    try:
        write_pillow(path)
        print("icon written with Pillow: %s" % path)
    except Exception as exc:  # noqa: BLE001
        print("Pillow unavailable (%s); falling back to stdlib renderer" % exc)
        write_stdlib(path)
        print("icon written with stdlib: %s" % path)
    print("size=%d bytes" % os.path.getsize(path))


if __name__ == "__main__":
    main()
