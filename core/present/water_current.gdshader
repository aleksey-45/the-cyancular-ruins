shader_type canvas_item;

#include "res://core/present/time_film.gdshaderinc"

uniform vec2 map_size = vec2(1.0);
uniform float elapsed;
uniform float coverage;
instance uniform bool wave = false;
uniform float wave_speed;
uniform float wave_amplitude;

varying vec2 water_pixel;

void vertex() {
	if (wave) {
		// 水纹随表层网格伸缩。顶点色记录波形相位和权重。
		water_pixel = UV / TEXTURE_PIXEL_SIZE;
		VERTEX.y += sin(elapsed * wave_speed + COLOR.r * TAU) * wave_amplitude * COLOR.g;
		COLOR = vec4(1.0);
	} else {
		water_pixel = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
	}
}

float stripe_strength(vec2 pixel) {
	float band = floor(mod(pixel.y, 64.0) / 16.0);
	float center = 5.5 + mod(band * 3.0 + 3.0, 7.0);
	float height = max(0.0, 1.0 - abs(mod(pixel.y, 16.0) - center) * 0.5);
	float x = mod(pixel.x - floor(elapsed * 18.0) + band * 23.0, 64.0) - 0.5;
	float length_px = 28.0 + mod(band, 2.0) * 5.0;
	float long_stripe = clamp(min(x, length_px - x) / 5.0, 0.0, 1.0);
	float short_stripe = clamp(min(x - 44.0, 53.0 - x) / 3.0, 0.0, 1.0);
	return height * (long_stripe * 0.19 + short_stripe * 0.12);
}

void fragment() {
	// 环面地图的副本沿用原位置的水纹相位。
	vec2 pixel = wave ? water_pixel : mod(water_pixel, map_size);
	COLOR.rgb = mix(COLOR.rgb, vec3(1.0), stripe_strength(pixel));
	if (!wave && coverage > 0.0) {
		COLOR.rgb = rewind_film_color(COLOR.rgb, SCREEN_UV, coverage);
	}
}
