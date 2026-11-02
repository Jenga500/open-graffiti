// Overwrites the canvas with a stored snapshot (used for undo).
shader_type canvas_item;
render_mode blend_disabled, unshaded;

void fragment() {
	COLOR = texture(TEXTURE, UV);
}
