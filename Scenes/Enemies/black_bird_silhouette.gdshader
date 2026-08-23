shader_type canvas_item;
// 黑鸟瞬移白闪:silhouette=1 时输出纯白剪影(保留贴图 alpha、隐去颜色),否则正常渲染。
uniform float silhouette : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	COLOR = mix(tex, vec4(vec3(1.0), tex.a), silhouette);
}
