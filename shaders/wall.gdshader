// Concrete block wall with the paint canvas (premultiplied, sRGB) on top.
shader_type spatial;

uniform sampler2D paint_tex : filter_linear, repeat_disable;
uniform vec2 wall_size = vec2(6.0, 3.0);
uniform vec2 block_size = vec2(0.4, 0.2);
uniform vec3 block_color : source_color = vec3(0.62, 0.6, 0.57);
uniform vec3 mortar_color : source_color = vec3(0.45, 0.44, 0.42);

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

void fragment() {
	vec2 p = vec2(UV.x * wall_size.x, (1.0 - UV.y) * wall_size.y);
	vec2 b = p / block_size;
	b.x += mod(floor(b.y), 2.0) * 0.5;
	vec2 f = fract(b);
	vec2 edge_dist = min(f, 1.0 - f) * block_size;
	float mortar = 1.0 - smoothstep(0.004, 0.008, min(edge_dist.x, edge_dist.y));
	float n = value_noise(p * 45.0) * 0.5 + value_noise(p * 6.0) * 0.5;
	vec3 base = block_color * (0.88 + 0.12 * hash(floor(b))) * (0.85 + 0.3 * n);
	base = mix(base, mortar_color, mortar);

	vec4 paint = texture(paint_tex, UV);
	vec3 paint_col = paint.a > 0.001 ? srgb_to_linear(clamp(paint.rgb / paint.a, 0.0, 1.0)) : vec3(0.0);
	ALBEDO = mix(base, paint_col, paint.a);
	ROUGHNESS = mix(0.95, 0.5, paint.a);
}
