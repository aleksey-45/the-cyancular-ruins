shader_type canvas_item;
// PvP 区分双方:给角色本体 AnimatedSprite2D 挂本 shader,色相旋转 hue_shift 度。
// 只染本体,武器/预瞄线等其它节点不受影响。
//
// ★ Godot 4 的 canvas_item fragment **入参 `COLOR` 已经等于「顶点色(modulate)× 纹理采样」**
//   (官方 shader 参考的 fragment 表:`COLOR` = "Color from the vertex function multiplied by
//   the texture color")⇒ 原地改色相即可,**不要再乘纹理**。
//   旧实现的 `COLOR = tex * COLOR` 是把纹理乘了**两次**(输出 = rotate(tex) × tex × modulate):
//   逐通道乘积把颜色压灰(蓝 → 青会被拉回成暗蓝),alpha 也被平方。
//   ★ 2026-09-19 实测(`.superpowers/sdd/_hue_probe.*` 真渲染取色):
//       修复前 hue_shift=-43 ⇒ 渲染出 `#269BF3`(色相 205.8°,**不是**青);
//       修复后同一参数 ⇒ `#63FFF3`(色相 175.4° = 218.5° - 43°,饱和/明度与本体主色一致)。
//   ★ 修法:只覆写 `COLOR.rgb`,`COLOR.a` **一字不动** —— 入参 alpha 已含
//     「纹理 alpha × modulate.a」,再乘一次就是平方。
//     受击白闪/无敌帧半透明(modulate)因此原样保住:alpha 恰好只乘一次、亮度随 modulate 缩放。
//     (alpha 那一半**在本素材上看不出差别** —— `player.png` 的 alpha 是二值的(0/255,
//      4 万像素里没有一个半透明像素),`tex.a` 在可见处恒为 1 ⇒ 平方前后同值;
//      真正可见的是上面那半 rgb 的压灰。)
//   测法:把 hue_shift 设 0 跑一遍,渲染结果应与"不挂本 shader"逐像素相同(而不是被压暗的 tex²)。

uniform float hue_shift : hint_range(-180.0, 180.0) = -43.0;  // 度:色相旋转量(负=反向),白/灰不变

vec3 rgb2hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 hsv2rgb(vec3 c) {
	vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
	vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
	return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

void fragment() {
	// 只改色相:读**入参** COLOR(已含纹理),写回 rgb;alpha 原样透传。
	vec3 hsv = rgb2hsv(COLOR.rgb);
	hsv.x = fract(hsv.x + hue_shift / 360.0);
	COLOR.rgb = hsv2rgb(hsv);
}
