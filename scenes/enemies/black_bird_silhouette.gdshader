shader_type canvas_item;
uniform float silhouette : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	COLOR = mix(tex, vec4(vec3(1.0), tex.a), silhouette);
}
