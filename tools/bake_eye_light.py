"""烘焙角色的接触阴影和双眼光斑，并记录动画帧的眼睛挂点。"""
from pathlib import Path
import re

import numpy as np
from PIL import Image, PngImagePlugin

ROOT = Path(__file__).resolve().parents[1]
TEXTURES = ROOT / 'assets/textures'
PLAYER = ROOT / 'scenes/player'
HEIGHT = 3.0  # 眼柱高，单位为原画像素
SIZE = 320
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


def eye_irradiance(pixels, points):
    center = pixels.mean(axis=0)
    variance, axes = np.linalg.eigh(np.cov(pixels.T, bias=True))
    # 矩形边长为各主轴标准差的 √12 倍，每个单位像素自身的方差为 1/12。
    half_size = np.sqrt(3 * variance + 0.25)
    px, py = ((points - center) @ axes).T
    x, wx = axis_samples(-half_size[0] - px, half_size[0] - px)
    y, wy = axis_samples(-half_size[1] - py, half_size[1] - py)
    light = np.zeros(len(points))
    for dx, weight in zip(x.T, wx.T):
        r2 = dx[:, None]**2 + y**2
        # 在平面上求照度，沿柱高积分 z / r³。
        column = 1 / np.sqrt(r2) - 1 / np.sqrt(r2 + HEIGHT**2)
        light += weight * (wy * column).sum(axis=1)
    return light


def bake_cookie(eyes, scale):
    pixels = np.argwhere(eyes)[:, ::-1] + 0.5
    pixels = pixels[pixels[:, 0].argsort()]
    gap = np.diff(pixels[:, 0]).argmax() + 1
    sources = pixels[:gap], pixels[gap:]
    center = (sources[0].mean(axis=0) + sources[1].mean(axis=0)) * 0.5
    y, x = np.indices((SIZE, SIZE))
    points = center + (np.column_stack((x.ravel(), y.ravel())) + 0.5 - SIZE / 2) / scale
    light = np.concatenate([
        sum(eye_irradiance(eye, chunk) for eye in sources)
        for chunk in np.array_split(points, 20)
    ]).reshape(x.shape)
    light /= light.max()
    srgb = np.where(light <= 0.0031308, light * 12.92, 1.055 * light ** (1 / 2.4) - 0.055)
    cookie = np.rint(srgb * 255).astype(np.uint8)
    cookie[[0, -1], :] = 0
    cookie[:, [0, -1]] = 0
    return Image.fromarray(cookie).convert('RGB')


def bake_eye_offsets(frames, eyes):
    def annotate(match):
        x, y, width, height = map(int, match[2].split(','))
        points = np.argwhere(eyes[y:y + height, x:x + width])
        dy, dx = points.mean(axis=0) + 0.5 - np.array([height, width]) / 2
        return f'{match[1]}\nmetadata/eye_offset = Vector2({dx:.9g}, {dy:.9g})'

    frames = re.sub(r'(?m)^metadata/eye_offset = [^\n]*\n?', '', frames)
    return re.sub(r'(?m)^(region = Rect2\(([^)]+)\))$', annotate, frames)


def bake_diffuse(sprite, eyes):
    shade = np.asarray(Image.open(TEXTURES / 'player_shade.png').getchannel('B'))
    transmission = 1.0 - 0.35 * np.where(eyes, 0, shade) / 255.0
    diffuse = sprite.copy()
    diffuse[:, :, :3] = np.rint(sprite[:, :, :3] * transmission[:, :, None])
    return Image.fromarray(diffuse)


def main():
    sprite = np.asarray(Image.open(TEXTURES / 'player.png').convert('RGBA'))
    eyes = np.all(sprite == 255, axis=2)
    frames_path = PLAYER / 'player_frames.tres'
    frames = frames_path.read_text(encoding='utf-8')
    idle_frames = re.search(r'"frames":\s*\[([^\]]+)\],\s*"loop":\s*\d+,\s*"name": &"idle"', frames)[1]
    idle = re.search(r'SubResource\("([^"]+)"\)', idle_frames)[1]
    region = re.search(rf'id="{re.escape(idle)}"\]\s*atlas = .*?\s*region = Rect2\(([^)]+)\)', frames)[1]
    x, y, width, height = map(int, region.split(','))
    config = (ROOT / 'core/config/player_config.tres').read_text(encoding='utf-8')
    scale = float(re.search(r'^body_scale = ([\d.]+)$', config, re.MULTILINE)[1])
    info = PngImagePlugin.PngInfo()
    info.add(b'sRGB', b'\x00')
    bake_diffuse(sprite, eyes).save(TEXTURES / 'player_diffuse.png', pnginfo=info)
    bake_cookie(eyes[y:y + height, x:x + width], scale).save(
        TEXTURES / 'player_light_cookie.png', pnginfo=info)
    frames_path.write_text(bake_eye_offsets(frames, eyes), encoding='utf-8', newline='\n')


if __name__ == '__main__':
    main()
