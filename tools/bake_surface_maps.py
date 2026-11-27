"""Bake pixel-aligned Godot normal and specular maps from the game's sprite palettes."""
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
TEXTURES = ROOT / "assets/textures"


def pixels(name):
    return np.array(Image.open(TEXTURES / (name + ".png")).convert("RGBA"))


def luminance(rgba):
    return rgba[:, :, :3] @ np.array([0.21, 0.72, 0.07]) / 255


def neighbors(field, repeating):
    pad = np.pad(field, 1, mode="wrap" if repeating else "constant")
    return pad[1:-1, :-2], pad[1:-1, 2:], pad[:-2, 1:-1], pad[2:, 1:-1]


def bevel(solid, repeating=False):
    # Concentric one-texel steps round the silhouette without smoothing its outline.
    height = np.zeros(solid.shape)
    for weight in (1.0, 0.8, 0.6, 0.4, 0.2):
        height += solid * weight
        left, right, up, down = neighbors(solid, repeating)
        solid = solid & left & right & up & down
    return height


def normals(height, solid, repeating=False):
    left, right, up, down = neighbors(height, repeating)
    # Godot's source normal maps use +Y up. Image rows increase downwards.
    vectors = np.stack(((left - right) / 2, (down - up) / 2, np.ones_like(height)), axis=2)
    vectors /= np.linalg.norm(vectors, axis=2, keepdims=True)
    vectors[~solid] = (0, 0, 1)
    return np.rint((vectors + 1) * 127.5).astype(np.uint8)


def specular(solid, strength, gloss):
    # RGB controls reflection strength. Alpha sets its width independently of sprite opacity.
    values = np.empty((*solid.shape, 4), dtype=np.uint8)
    values[:, :, :3] = np.rint(strength)[..., None]
    values[:, :, 3] = gloss
    values[~solid] = 0
    return values


def save(name, kind, values):
    Image.fromarray(values).save(TEXTURES / f"{name}_{kind}.png")


def weapons():
    rgba = pixels("weapons")
    solid = rgba[:, :, 3] > 0
    mask = Image.new("1", (rgba.shape[1], rgba.shape[0]))
    pen = ImageDraw.Draw(mask)
    # Stocks, grips and the bow grip have the same blue palette as the metal body.
    for polygon in (
        [(2, 7), (9, 7), (6, 14), (2, 14)],
        [(22, 5), (34, 5), (33, 12), (22, 15)],
        [(39, 10), (43, 10), (41, 17), (37, 17)],
        [(108, 10), (124, 6), (124, 10), (108, 16)],
        [(126, 12), (131, 12), (128, 19), (124, 19)],
        [(2, 27), (21, 20), (25, 20), (21, 24), (6, 34), (2, 34)],
        [(72, 29), (84, 30), (80, 36), (71, 36)],
        [(3, 42), (16, 42), (14, 52), (5, 52)],
        [(11, 52), (18, 47), (20, 49), (15, 56), (11, 56)],
        [(62, 45), (81, 45), (79, 49), (69, 56), (62, 52)],
        [(83, 51), (90, 51), (86, 60), (81, 60)],
        [(14, 76), (19, 76), (19, 87), (14, 87)],
    ):
        pen.polygon(polygon, fill=1)
    grip = np.asarray(mask)
    tone = luminance(rgba)
    height = 0.85 * bevel(solid) + solid * (2.4 * tone + 0.3 * grip)
    save("weapons", "normal", normals(height, solid))
    save("weapons", "specular", specular(solid, np.where(grip, 8, 36 + 58 * tone),
                                          np.where(grip, 48, 150 + 45 * tone)))


def birds():
    for name in ("jump_bird", "fly_bird", "black_bird"):
        rgba = pixels(name)
        normal = np.full((*rgba.shape[:2], 3), (128, 128, 255), dtype=np.uint8)
        spec = np.zeros_like(rgba)
        for y in range(0, rgba.shape[0], 48):
            for x in range(0, rgba.shape[1], 48):
                region = np.s_[y:y + 48, x:x + 48]
                frame = rgba[region]
                solid = frame[:, :, 3] > 0
                red, green, blue = frame[:, :, :3].astype(int).transpose(2, 0, 1)
                row, col = np.indices(solid.shape)
                if name == "black_bird":
                    hard = (red > 1.3 * blue) | ((red == blue) & (green == blue))
                elif name == "jump_bird":
                    hard = ((col >= 38) & (red < 75)) | ((red == 27) & (green == 31))
                else:
                    hard = ((col >= 38) & (red < 44)) | ((row > 29) & (green > blue) & (green < 110))
                tone = luminance(frame)
                height = 0.7 * bevel(solid) + solid * (1.8 * tone + 0.35 * hard)
                normal[region] = normals(height, solid)
                spec[region] = specular(solid, np.where(hard, 55, 7 + 14 * tone),
                                        np.where(hard, 165, 62))
        save(name, "normal", normal)
        save(name, "specular", spec)


def street_lamp():
    rgba = pixels("street_lamp")
    solid = rgba[:, :, 3] > 0
    tone = luminance(rgba)
    y, x = np.indices(solid.shape)
    glass = (y >= 10) & (y <= 21) & (x >= 5) & (x <= 10)
    height = 0.9 * bevel(solid) + solid * (1.8 * tone + 0.6 * glass)
    save("street_lamp", "normal", normals(height, solid))
    save("street_lamp", "specular", specular(solid, np.where(glass, 92, 30 + 54 * tone),
                                             np.where(glass, 210, 140)))


def terrain():
    rgba = pixels("structure")
    normal = np.full((*rgba.shape[:2], 3), (128, 128, 255), dtype=np.uint8)
    spec = np.zeros_like(rgba)
    tiles = json.loads((ROOT / "data/tile_defs.json").read_text(encoding="utf-8"))["tiles"]
    yy, xx = np.indices((32, 32))
    for tile in map(int, tiles):
        y, x = divmod(tile - 1, 10)
        region = np.s_[y * 32:(y + 1) * 32, x * 32:(x + 1) * 32]
        brick = rgba[region]
        solid = brick[:, :, 3] > 0
        tone = luminance(brick)
        relief = tone - tone[solid].min()
        height = 0.8 * bevel(solid, repeating=True) + 5.0 * relief
        strength, gloss = 10 + 20 * relief, 65
        if tile in (12, 13, 14):  # Iron chain and its two anchors.
            height += 3 * relief
            strength, gloss = 51 + 65 * relief, 180
        elif tile in (11, 19, 20):  # Ladder, upright and horizontal grain.
            grain = xx if tile == 19 else yy
            height += 0.22 * np.sin(grain * np.pi / 4)
            strength, gloss = 7 + 11 * relief, 45
        elif tile == 15:
            strength, gloss = 15 + 38 * relief, 105
        elif tile in (21, 22):
            phase = (xx + 2 * yy) * np.pi / 16
            height = (0.18 if tile == 21 else 0.48) * np.sin(phase) + 1.6 * relief
            strength, gloss = (18 if tile == 21 else 50) + 30 * relief, 152
        normal[region] = normals(height, solid, repeating=True)
        spec[region] = specular(solid, strength, gloss)
    save("structure", "normal", normal)
    save("structure", "specular", spec)


if __name__ == "__main__":
    weapons()
    birds()
    street_lamp()
    terrain()
    player = pixels("player")
    eyes = (player == 255).all(axis=2)
    save("player", "specular", specular(player[:, :, 3] > 0,
                                        np.where(eyes, 5, 11 + 12 * luminance(player)),
                                        np.where(eyes, 150, 88)))
