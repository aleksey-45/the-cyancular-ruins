shader_type canvas_item;
// 角色本体的**个人色相**旋转:给 AnimatedSprite2D 挂本 shader,色相旋转 hue_shift 度。
// 只染本体,武器/预瞄线等其它节点不受影响。
//
// -  谁在用(2026-09-20 起):**只有个人色相** —— 大乱斗的对手色(`royale_game._apply_peer_hues`)
//   与大乱斗/3v3 里**自己**那把自选色(`Settings.pvp_color_hue`),都经
//   `PvpMatchClient._apply_tint` 的第二条分支。
//   -  **1v1 的 P2 已不走这里** —— 它与大乱斗/3v3 的**队色**一样改走 `_apply_tint` 的
//     modulate **比值**那条路(理由:hue 旋转保持饱和度/亮度不变,表达不了用户选的 S50 青)。
//     本文件因此不再被 `pvp_game.gd` 引用;文件名里的 `p2` 是历史(2026-09-19 前它是 P2 专属)。
//
// -  Godot 4 的 canvas_item fragment **入参 `COLOR` 已经等于「顶点色(modulate)× 纹理采样」**
//   (官方 shader 参考的 fragment 表:`COLOR` = "Color from the vertex function multiplied by
//   the texture color") ->  原地改色相即可,**不要再乘纹理**。
//   旧实现的 `COLOR = tex * COLOR` 是把纹理乘了**两次**(输出 = rotate(tex) × tex × modulate):
//   逐通道乘积把颜色压灰(蓝 → 青会被拉回成暗蓝),alpha 也被平方。
//   -  2026-09-19 实测(`.superpowers/sdd/_hue_probe.*` 真渲染取色;当时 `hue_shift = -43.0`
//     还是 1v1 的 P2 设置,那个用法 2026-09-20 已删,下列数字仍是本 shader 旋转正确性的证据):
//       修复前 hue_shift=-43  ->  渲染出 `#269BF3`(色相 205.8°,**不是**青);
//       修复后同一参数  ->  `#63FFF3`(色相 175.4° = 218.5° - 43°,饱和/明度与本体主色一致)。
//   -  修法:只覆写 `COLOR.rgb`,`COLOR.a` **一字不动** —— 入参 alpha 已含
//     「纹理 alpha × modulate.a」,再乘一次就是平方。
//     受击白闪/无敌帧半透明(modulate)因此原样保住:alpha 恰好只乘一次、亮度随 modulate 缩放。
//     (alpha 那一半**在本素材上看不出差别** —— `player.png` 的 alpha 是二值的(0/255,
//      4 万像素里没有一个半透明像素),`tex.a` 在可见处恒为 1  ->  平方前后同值;
//      真正可见的是上面那半 rgb 的压灰。)
//   测法:把 hue_shift 设 0 跑一遍,渲染结果应与"不挂本 shader"逐像素相同(而不是被压暗的 tex²)。
//   (守卫:`tests/hue_tint_probe` 守卫 A —— 它 2026-09-20 起守的是**个人色相**这条路。)

// 度:色相旋转量(负=反向),白/灰不变。
// -  默认值 2026-09-20 由 `-43.0` 改为 `0.0`:`-43.0` 是当年"1v1 的 P2 色相"的残留(P2 已于同日
//   改走 modulate 比值),而"材料没显式设过参数"最合理的语义是**不改色**(0 = 恒等)。
//   生产路径每次都会显式 `set_shader_parameter`(`_apply_tint` 的色相分支),故无人依赖旧默认值。
uniform float hue_shift : hint_range(-180.0, 180.0) = 0.0;

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
