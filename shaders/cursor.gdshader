// Aim ring shown on the wall where the can is pointing.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;

uniform vec4 ring_color : source_color = vec4(1.0, 1.0, 1.0, 0.8);

void fragment() {
	float d = length(UV - 0.5) * 2.0;
	float ring = 1.0 - smoothstep(0.02, 0.06, abs(d - 0.9));
	float dot_c = 1.0 - smoothstep(0.04, 0.08, d);
	float outline = (1.0 - smoothstep(0.06, 0.1, abs(d - 0.9))) - ring;
	ALBEDO = mix(vec3(0.0), ring_color.rgb, ring + dot_c);
	ALPHA = clamp(ring + dot_c + outline * 0.6, 0.0, 1.0) * ring_color.a;
}
