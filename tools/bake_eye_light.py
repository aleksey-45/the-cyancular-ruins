"""按皮肤的表面朝向，烘焙两根均匀发光眼柱的漫反射照度。"""
from pathlib import Path
import re

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
TEXTURES = ROOT / 'assets/textures'
PLAYER = ROOT / 'scenes/player'
HEIGHT = 3.0  # 柱底贴脸，凸起高度与待机眼条的宽度相同，单位为原画像素
SCALE = 2
nodes, weights = np.polynomial.legendre.leggauss(16)
unit = (nodes + 1) / 2
SAMPLES, WEIGHTS = unit**2, unit * weights


def axis_samples(low, high):
    """从距离皮肤像素最近的一端密集取样，积分区间不跨过像素所在位置。"""
    middle = np.where(low * high < 0, 0.0, (low + high) / 2)
    edges = np.stack((low, middle, high), axis=1)
    a, b = edges[:, :-1, None], edges[:, 1:, None]
    near = np.clip(0.0, a, b)
    samples = near + (a + b - 2 * near) * SAMPLES
    return samples.reshape(len(low), -1), ((b - a) * WEIGHTS).reshape(len(low), -1)


def eye_irradiance(pixels, points, normals):
    center = pixels.mean(axis=0)
    variance, axes = np.linalg.eigh(np.cov(pixels.T, bias=True))
    # 矩形边长为各主轴标准差的 √12 倍，每个单位像素自身的方差为 1/12。
    half_size = np.sqrt(3 * variance + 0.25)
    px, py = ((points - center) @ axes).T
    nx, ny = (normals[:, :2] @ axes).T
    nz = normals[:, 2, None]
    x, wx = axis_samples(-half_size[0] - px, half_size[0] - px)
    y, wy = axis_samples(-half_size[1] - py, half_size[1] - py)
    light = np.zeros(len(points))
    for dx, weight in zip(x.T, wx.T):
        r2 = dx[:, None]**2 + y**2
        tilt = (nx * dx)[:, None] + ny[:, None] * y
        # 只计皮肤切平面正面的光。沿柱高积分 (tilt + nz*z) / r³。
        bottom = np.clip(-tilt / nz, 0, HEIGHT)
        near = np.sqrt(r2 + bottom**2)
        far = np.sqrt(r2 + HEIGHT**2)
        column = nz * (1 / near - 1 / far) + (tilt / r2) * (HEIGHT / far - bottom / near)
        light += weight * (wy * column).sum(axis=1)
    return light


def bake_frame(eyes, shade, curvature):
    pixels = np.argwhere(eyes)[:, ::-1] + 0.5
    pixels = pixels[pixels[:, 0].argsort()]
    gap = np.diff(pixels[:, 0]).argmax() + 1
    y, x = np.indices(np.array(eyes.shape) * SCALE)
    points = (np.column_stack((x.ravel(), y.ravel())) + 0.5) / SCALE
    xy = (shade[y // SCALE, x // SCALE, :2].reshape(-1, 2) / 127.5 - 1) * curvature
    normals = np.column_stack((xy, np.sqrt(1 - (xy * xy).sum(axis=1))))
    light = sum(eye_irradiance(eye, points, normals) for eye in (pixels[:gap], pixels[gap:]))
    return np.rint(light.reshape(x.shape) * (255 / (2 * np.pi * HEIGHT))).astype(np.uint8)


def main():
    sprite = np.asarray(Image.open(TEXTURES / 'player.png').convert('RGBA'))
    shade = np.asarray(Image.open(TEXTURES / 'player_shade.png').convert('RGB'))
    shader = (PLAYER / 'player_color.gdshader').read_text(encoding='utf-8')
    curvature = float(re.search(r'\bSKIN_CURVATURE\s*=\s*([\d.]+)', shader)[1])
    eyes = np.all(sprite == 255, axis=2)
    light = Image.new('L', (eyes.shape[1] * SCALE, eyes.shape[0] * SCALE))
    frames = (PLAYER / 'player_frames.tres').read_text(encoding='utf-8')
    for region in re.findall(r'^region = Rect2\(([^)]+)\)', frames, re.MULTILINE):
        x, y, width, height = map(int, region.split(','))
        region = np.s_[y:y + height, x:x + width]
        frame = bake_frame(eyes[region], shade[region], curvature)
        light.paste(Image.fromarray(frame), (x * SCALE, y * SCALE))
    light.save(TEXTURES / 'player_eye_light.png')


if __name__ == '__main__':
    main()
