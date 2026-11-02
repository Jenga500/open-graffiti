// Draws one spray stamp into the paint canvas.
// The canvas stores premultiplied alpha, so stamps are blended with blend_premul_alpha.
// The brush texture only provides the falloff (alpha); the tint comes from the draw modulate.
shader_type canvas_item;
render_mode blend_premul_alpha, unshaded;

varying vec4 tint;

void vertex() {
	tint = COLOR;
}

void fragment() {
	float a = clamp(tint.a * texture(TEXTURE, UV).a, 0.0, 1.0);
	COLOR = vec4(tint.rgb * a, a);
}
