#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 1024x1024 的 App 图标（纯文本脚本，无外部资源）。

优先用 Pillow 画得细一点；没有 Pillow 就退化到纯标准库（zlib + struct）的
逐像素实现，保证 CI 上「一定有图标可用」，不会因为缺依赖让构建失败。

图形：浅灰白渐变底 + 一对方向相反的粗箭头（上橙下墨，入 / 出），对应 App 名 InOut。
两条渲染路径共用下面这组几何常量，改形状只改这里。

用法：python3 tools/make_appicon.py [输出目录]
默认输出到 InOut/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
"""

import os
import struct
import sys
import zlib

SIZE = 1024

# 浅色系：灰白渐变底 + 加深一点的热度橙 + 墨色
BG_TOP = (250, 250, 252)
BG_BOTTOM = (232, 232, 237)
ORANGE = (233, 84, 28)
INK = (28, 28, 32)

# --- 箭头几何（1024 画布，水平成对、方向相反）---
SHAFT_HALF = 76.0       # 箭杆半高（短粗：更厚的杆）
HEAD_HALF_H = 150.0     # 箭头半高
HEAD_LEN = 185.0        # 箭头长度
X_LEFT = 232.0          # 图形左边界
X_RIGHT = 792.0         # 图形右边界
Y_TOP = 376.0           # 上面那根（向右 = In）的中心线
Y_BOTTOM = 648.0        # 下面那根（向左 = Out）的中心线

# 上面向右、下面向左：箭头尖端坐标
UP_HEAD = (
    (X_RIGHT - HEAD_LEN, Y_TOP - HEAD_HALF_H),
    (X_RIGHT - HEAD_LEN, Y_TOP + HEAD_HALF_H),
    (X_RIGHT, Y_TOP),
)
DOWN_HEAD = (
    (X_LEFT + HEAD_LEN, Y_BOTTOM - HEAD_HALF_H),
    (X_LEFT + HEAD_LEN, Y_BOTTOM + HEAD_HALF_H),
    (X_LEFT, Y_BOTTOM),
)

# 箭杆往箭头里伸半个杆高：圆头被箭头盖住，两者交界处是一条干净的肩线。
UP_SHAFT = (X_LEFT, Y_TOP - SHAFT_HALF, X_RIGHT - HEAD_LEN + SHAFT_HALF, Y_TOP + SHAFT_HALF)
DOWN_SHAFT = (X_LEFT + HEAD_LEN - SHAFT_HALF, Y_BOTTOM - SHAFT_HALF, X_RIGHT, Y_BOTTOM + SHAFT_HALF)


def _blend(dst, src, alpha):
    return tuple(int(round(d * (1 - alpha) + s * alpha)) for d, s in zip(dst, src))


def _rounded_rect_alpha(x, y, x0, y0, x1, y1, r):
    """点 (x,y) 在圆角矩形内的覆盖率，1.0 表示完全在内。

    用圆角矩形的有符号距离场：先按中心算到「内缩矩形」的距离，再减掉半径。
    注意不能拿 bounding box 判断直边区域 —— 圆角外侧的角点也在 box 里。
    """
    cx = (x0 + x1) / 2.0
    cy = (y0 + y1) / 2.0
    half_w = (x1 - x0) / 2.0
    half_h = (y1 - y0) / 2.0
    qx = abs(x - cx) - (half_w - r)
    qy = abs(y - cy) - (half_h - r)
    outside = (max(qx, 0.0) ** 2 + max(qy, 0.0) ** 2) ** 0.5
    dist = outside + min(max(qx, qy), 0.0) - r
    return max(0.0, min(1.0, 0.5 - dist))


def _triangle_alpha(x, y, points):
    """点 (x,y) 在三角形内的覆盖率（凸多边形：取到各边有向距离的最小值）。

    顶点顺序任意，用有向面积判断朝向，把「内侧」统一成正数。
    """
    area = 0.0
    for i in range(3):
        ax, ay = points[i]
        bx, by = points[(i + 1) % 3]
        area += ax * by - bx * ay
    sign = 1.0 if area > 0 else -1.0

    depth = None
    for i in range(3):
        ax, ay = points[i]
        bx, by = points[(i + 1) % 3]
        cross = (bx - ax) * (y - ay) - (by - ay) * (x - ax)
        length = ((bx - ax) ** 2 + (by - ay) ** 2) ** 0.5
        signed = sign * cross / length
        depth = signed if depth is None else min(depth, signed)
    return max(0.0, min(1.0, depth + 0.5))


def _arrow_alpha(x, y, shaft, head):
    """箭杆（圆角矩形）与箭头（三角形）的并集覆盖率。"""
    a = _rounded_rect_alpha(x, y, shaft[0], shaft[1], shaft[2], shaft[3], SHAFT_HALF)
    b = _triangle_alpha(x, y, head)
    return a if a > b else b


def _pixel(x, y):
    """返回 (r, g, b)：垂直渐变背景 + 上入（橙）下出（墨）一对箭头。"""
    t = y / float(SIZE - 1)
    color = tuple(int(round(a + (b - a) * t)) for a, b in zip(BG_TOP, BG_BOTTOM))

    a = _arrow_alpha(x, y, DOWN_SHAFT, DOWN_HEAD)
    if a > 0:
        color = _blend(color, INK, a)

    a = _arrow_alpha(x, y, UP_SHAFT, UP_HEAD)
    if a > 0:
        color = _blend(color, ORANGE, a)

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

    # 4× 超采样再缩回 1024：斜边（箭头尖）不会出现硬锯齿。
    scale = 4
    big = SIZE * scale
    img = Image.new("RGB", (big, big), BG_BOTTOM)
    draw = ImageDraw.Draw(img)
    for y in range(big):
        t = y / float(big - 1)
        draw.line(
            [(0, y), (big, y)],
            fill=tuple(int(round(a + (b - a) * t)) for a, b in zip(BG_TOP, BG_BOTTOM)),
        )

    def rect(box, fill):
        draw.rounded_rectangle(
            [box[0] * scale, box[1] * scale, box[2] * scale, box[3] * scale],
            radius=SHAFT_HALF * scale,
            fill=fill,
        )

    def triangle(points, fill):
        draw.polygon([(px * scale, py * scale) for px, py in points], fill=fill)

    rect(DOWN_SHAFT, INK)
    triangle(DOWN_HEAD, INK)
    rect(UP_SHAFT, ORANGE)
    triangle(UP_HEAD, ORANGE)

    img.resize((SIZE, SIZE), Image.LANCZOS).save(path, "PNG")


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        "InOut", "Assets.xcassets", "AppIcon.appiconset"
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
