shader_type canvas_item;
render_mode unshaded;

uniform vec4 ambient_light : source_color = vec4(1.0);
uniform vec3 directional_light = vec3(0.0, -1.0, 1.0);
uniform sampler2D shade_atlas : filter_nearest, repeat_disable;
uniform float eye_reflection : hint_range(0.0, 1.0) = 0.55;
uniform sampler2D eye_irradiance : filter_linear, repeat_disable;

const vec3 BASE_SKIN = vec3(99.0, 155.0, 255.0) / 255.0;
const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);
const float SKIN_CURVATURE = 0.45;
const float EYE_POWER = 2.0;
const float EYE_SOURCE_WEIGHT = 0.55;
varying vec3 eye_color;
varying vec3 eye_light;
varying vec3 local_light;

void vertex() {
	vec2 direction = directional_light.xy;
	local_light = normalize(vec3(dot(direction, normalize(MODEL_MATRIX[0].xy)),
			dot(direction, normalize(MODEL_MATRIX[1].xy)), 1.0));
	vec3 skin = BASE_SKIN * COLOR.rgb;
	vec3 eye_source = 1.06 * mix(skin, vec3(1.0), 0.45);
	vec3 base_eye = min(mix(ambient_light.rgb, eye_source, EYE_SOURCE_WEIGHT), vec3(1.0));
	float emission = EYE_POWER * max(dot(base_eye - ambient_light.rgb, LUMA), 0.0);
	// 眼芯发射色处于 sRGB 曲线的幂函数段，先按线性光强增益，再混入天色。
	eye_source = (eye_source + 0.055) * pow(EYE_POWER, 1.0 / 2.4) - 0.055;
	eye_color = mix(ambient_light.rgb, eye_source, EYE_SOURCE_WEIGHT);
	vec3 white_light = mix(vec3(1.0), ambient_light.rgb, 0.5);
	eye_light = white_light * (eye_reflection * emission / dot(BASE_SKIN * white_light, LUMA));
}

float bayer2(vec2 pixel) {
	return fract(pixel.x * 0.5 + pixel.y * pixel.y * 0.75);
}

float body_shade(vec2 uv, vec2 pixel) {
	// RG 是各部位的局部坐标，B 是肢体贴合处的暗部。
	vec3 shade = texture(shade_atlas, uv).rgb;
	vec2 surface = (shade.rg * 2.0 - 1.0) * SKIN_CURVATURE;
	vec3 normal = vec3(surface, sqrt(1.0 - dot(surface, surface)));
	float facing = smoothstep(-0.20, 0.80, dot(normal, local_light));
	float dither = bayer2(floor(pixel * 0.5)) * 0.25 + bayer2(pixel) - 0.5;
	float shade_step = clamp(floor(facing * 5.0 + 0.25 * dither + 0.5) / 5.0, 0.0, 1.0);
	float strength = mix(0.198, 0.44, directional_light.z);
	return 1.05 * mix(1.0 - strength, 1.0, shade_step) * (1.0 - shade.b * 0.35);
}

void fragment() {
	if (all(equal(texture(TEXTURE, UV).rgb, vec3(1.0)))) {
		COLOR.rgb = eye_color;
	} else {
		vec3 ambient = ambient_light.rgb * body_shade(UV, floor(UV / TEXTURE_PIXEL_SIZE));
		// 烘焙照度以 2π × 柱高归一，漫反射以 π × 柱高归一。
		float irradiance = 2.0 * texture(eye_irradiance, UV).r;
		COLOR.rgb *= ambient + eye_light * irradiance;
	}
}
