shader_type canvas_item;

#include "res://core/present/time_film.gdshaderinc"

uniform float coverage : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	COLOR.rgb = rewind_film_color(COLOR.rgb, SCREEN_UV, coverage);
}
