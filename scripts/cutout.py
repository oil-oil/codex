#!/usr/bin/env python3
"""Remove background from PNG images using flood-fill from corners.

Usage:
    python3 cutout.py <input> <output>
    python3 cutout.py <input>              # overwrites in place
    python3 cutout.py <directory>           # processes all PNGs in dir

Backs up originals to a sibling `_raw/` directory when processing a dir.
"""
import sys, os, shutil
from pathlib import Path
from collections import deque
from PIL import Image


def flood_fill_remove(path_in, path_out, thresh=18, min_pocket=400):
    im = Image.open(path_in).convert('RGBA')
    # Keep an immutable copy for all colour sampling and classification.
    # The output image is mutated to transparent pixels as the fill proceeds;
    # sampling from that mutated image would turn later corner samples into
    # (0, 0, 0) and incorrectly classify real black artwork as background.
    source = im.copy()
    source_px = source.load()
    px = im.load()
    w, h = im.size
    corners = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]
    bg_colors = [source_px[cx, cy][:3] for cx, cy in corners]
    visited = set()
    for (cx, cy), bg in zip(corners, bg_colors):
        q = deque([(cx, cy)])
        while q:
            x, y = q.popleft()
            if (x, y) in visited or x < 0 or y < 0 or x >= w or y >= h:
                continue
            r, g, b, a = source_px[x, y]
            if a and abs(r - bg[0]) < thresh and abs(g - bg[1]) < thresh and abs(b - bg[2]) < thresh:
                visited.add((x, y))
                px[x, y] = (0, 0, 0, 0)
                for dx, dy in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
                    q.append((x + dx, y + dy))
    pockets = _clear_enclosed_pockets(source_px, px, w, h, bg_colors, thresh, min_pocket)
    im.save(path_out)
    print(f'cutout: {path_in} → {path_out}  ({len(visited)} px removed, {pockets} enclosed px cleared)')


def _clear_enclosed_pockets(source_px, output_px, w, h, bg_colors, thresh, min_area):
    """Ink lines / subject outlines often fence off pockets of background
    (between a character's legs, under furniture...) that corner flood-fill
    can't reach. Clear any large still-opaque region whose colour matches a
    corner background colour. Small regions are kept so anti-aliased greys
    inside the subject survive."""
    def is_bg(c):
        if c[3] == 0:
            return False
        return any(
            abs(c[0] - bg[0]) < thresh and abs(c[1] - bg[1]) < thresh and abs(c[2] - bg[2]) < thresh
            for bg in bg_colors
        )

    def is_remaining_bg(x, y):
        return output_px[x, y][3] != 0 and is_bg(source_px[x, y])

    seen = bytearray(w * h)
    cleared = 0
    for y0 in range(h):
        row = y0 * w
        for x0 in range(w):
            if seen[row + x0]:
                continue
            seen[row + x0] = 1
            if not is_remaining_bg(x0, y0):
                continue
            region = [(x0, y0)]
            q = deque([(x0, y0)])
            while q:
                x, y = q.popleft()
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < w and 0 <= ny < h and not seen[ny * w + nx]:
                        seen[ny * w + nx] = 1
                        if is_remaining_bg(nx, ny):
                            region.append((nx, ny))
                            q.append((nx, ny))
            if len(region) >= min_area:
                for x, y in region:
                    output_px[x, y] = (0, 0, 0, 0)
                cleared += len(region)
    return cleared


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    target = Path(sys.argv[1])

    if target.is_dir():
        raw_dir = target.parent / (target.name + '_raw')
        raw_dir.mkdir(exist_ok=True)
        for f in sorted(target.glob('*.png')):
            backup = raw_dir / f.name
            if not backup.exists():
                shutil.copy2(f, backup)
            flood_fill_remove(str(f), str(f))
    elif target.is_file():
        out = sys.argv[2] if len(sys.argv) > 2 else str(target)
        Path(out).parent.mkdir(parents=True, exist_ok=True)
        flood_fill_remove(str(target), out)
    else:
        print(f'Error: {target} not found')
        sys.exit(1)


if __name__ == '__main__':
    main()
