shader_type canvas_item;



uniform sampler2D map_tex : filter_nearest, repeat_enable;
uniform vec2  map_size   = vec2(150.0, 100.0);
uniform float view_w_cells = 26.6667;
uniform float fisheye    = 0.85;
uniform vec2  view_center = vec2(75.0, 50.0);
uniform float rot_angle  = 0.0;
uniform float breathe_amp = 0.012;
uniform float aberration = 0.020;
uniform float dim        = 0.60;
uniform float vignette   = 0.30;
uniform float desat      = 0.20;
uniform float blur_radius = 6.0;


vec2 rot2(vec2 v, float a) {
	float c = cos(a);
	float s = sin(a);
	return vec2(v.x * c - v.y * s, v.x * s + v.y * c);
}


vec2 menu_sample_uv(vec2 cc, float strength) {
	vec2 c = rot2(cc, rot_angle);
	float r = length(c);
	float rs = r * (1.0 + strength * r * r);
	vec2 dir = c / max(r, 0.00001);
	vec2 c2 = dir * rs;
	vec2 cell = view_center + c2 * view_w_cells;
	return cell / map_size;
}


vec3 bg_sample(vec2 cc) {
	return texture(map_tex, menu_sample_uv(cc, fisheye)).rgb;
}


vec3 bg_sample_ab(vec2 cc) {
	float ab = aberration * smoothstep(0.22, 0.60, length(cc));
	vec3 col;
	col.r = texture(map_tex, menu_sample_uv(cc, fisheye * (1.0 + ab))).r;
	col.g = texture(map_tex, menu_sample_uv(cc, fisheye)).g;
	col.b = texture(map_tex, menu_sample_uv(cc, fisheye * (1.0 - ab))).b;
	return col;
}


void fragment() {
	float aspect = SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	vec2 cc = vec2(UV.x - 0.5, (UV.y - 0.5) / aspect);
	cc *= 1.0 + breathe_amp * sin(TIME * 0.113);

	float r = length(cc);

	vec3 col;
	if (blur_radius < 0.5) {
		col = bg_sample_ab(cc);
	} else {
		vec2 sp = vec2(SCREEN_PIXEL_SIZE.x, SCREEN_PIXEL_SIZE.y / aspect) * blur_radius;
		col = bg_sample_ab(cc) * 4.0;
		col += bg_sample(cc + vec2(sp.x, 0.0)) * 2.0;
		col += bg_sample(cc + vec2(-sp.x, 0.0)) * 2.0;
		col += bg_sample(cc + vec2(0.0, sp.y)) * 2.0;
		col += bg_sample(cc + vec2(0.0, -sp.y)) * 2.0;
		col += bg_sample(cc + vec2(sp.x, sp.y));
		col += bg_sample(cc + vec2(-sp.x, sp.y));
		col += bg_sample(cc + vec2(sp.x, -sp.y));
		col += bg_sample(cc + vec2(-sp.x, -sp.y));
		col /= 16.0;
	}

	col = mix(col, vec3(0.0), dim);
	col = mix(col, vec3(dot(col, vec3(0.299, 0.587, 0.114))), desat);
	col *= mix(1.0, 1.0 - vignette, smoothstep(0.28, 0.66, r));
	COLOR = vec4(col, 1.0);
}
