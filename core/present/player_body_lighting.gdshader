shader_type canvas_item;

// RGB 记录环境光颜色，A 记录归一化的太阳高度。
uniform vec4 body_daylight : source_color;

float bayer2(vec2 pixel) {
	return fract(pixel.x * 0.5 + pixel.y * pixel.y * 0.75);
}

void light() {
	if (LIGHT_IS_DIRECTIONAL && !all(equal(texture(TEXTURE, UV).rgb, vec3(1.0)))) {
		vec3 direction = normalize(vec3(normalize(LIGHT_DIRECTION.xy), 1.0));
		float facing = smoothstep(-0.20, 0.80, dot(NORMAL, direction));
		vec2 pixel = floor(UV / TEXTURE_PIXEL_SIZE);
		float dither = bayer2(floor(pixel * 0.5)) * 0.25 + bayer2(pixel) - 0.5;
		float shade_step = clamp(floor(facing * 5.0 + 0.25 * dither + 0.5) / 5.0, 0.0, 1.0);
		float strength = mix(0.198, 0.44, body_daylight.a);
		float shade = 1.05 * mix(1.0 - strength, 1.0, shade_step);
		// 在 CanvasModulate 的环境光基础上叠加明暗分档的差值。
		LIGHT = vec4(COLOR.rgb * body_daylight.rgb * (shade - 1.0), 1.0);
	} else {
		// 眼部纯白纹素与点光源使用漫反射光照。
		float facing = max(dot(NORMAL, LIGHT_DIRECTION), 0.0);
		float energy = LIGHT_IS_DIRECTIONAL ? 1.0 : LIGHT_ENERGY;
		LIGHT = vec4(COLOR.rgb * LIGHT_COLOR.rgb * energy * facing, LIGHT_COLOR.a);
	}
}
