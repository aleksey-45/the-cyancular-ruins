shader_type canvas_item;
render_mode unshaded;

instance uniform float spacing = 1.0;
varying vec2 cell;

void vertex() {
	cell = VERTEX;
}

void fragment() {
	if (all(greaterThanEqual(mod(cell, spacing), fwidth(cell)))) {
		discard;
	}
}
