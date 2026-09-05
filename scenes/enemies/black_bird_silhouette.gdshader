shader_type canvas_item;
// 黑鸟纯白剪影 shader:silhouette=1 时输出纯白剪影(保留贴图 alpha),否则正常渲染。
// 受击/死亡/瞬移白闪统一走本参数(不走 modulate——Godot 4 自定义 canvas shader 覆写
// COLOR 时,节点 modulate 不生效,所以黑鸟白闪不能靠 modulate)。
uniform float silhouette : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	COLOR = mix(tex, vec4(vec3(1.0), tex.a), silhouette);
}
