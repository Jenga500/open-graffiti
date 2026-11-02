// Converts the premultiplied canvas back to straight alpha for PNG export.
shader_type canvas_item;
render_mode blend_disabled, unshaded;

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	COLOR = c.a > 0.0 ? vec4(clamp(c.rgb / c.a, 0.0, 1.0), c.a) : vec4(0.0);
}
