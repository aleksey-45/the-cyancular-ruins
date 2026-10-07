shader_type canvas_item;
// 纯白剪影着色器：当 silhouette = 1.0 时输出纯白剪影（保留原纹理 Alpha 通道），否则正常渲染。
// 受击、死亡闪白以及传送特效统一通过此参数控制。在 Godot 4 中，自定义 CanvasItem 着色器重写
// COLOR 顶点颜色后节点的 modulate 属性将被覆盖，因此黑鸟的高亮闪白通过着色器参数实现。
uniform float silhouette : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	COLOR = mix(tex, vec4(vec3(1.0), tex.a), silhouette);
}
