class_name SprayCan
extends Node3D

## Spray can held in the right hand.
##
## The node's origin is the nozzle, spraying along -Z. Trigger pressure sets the
## flow; the distance to the wall sets the radius and softness of the spray cone.
## Holding the can close in one spot builds up wet paint that starts to drip.

const CURSOR_SHADER := preload("res://shaders/cursor.gdshader")

## Paint range in meters
@export var max_distance := 1.0
## Spray radius at the nozzle (m)
@export var base_radius := 0.003
## Radius growth per meter of distance (cone spread)
@export var spread := 0.28
## Radius at which spray_rate is calibrated
@export var reference_radius := 0.03
## Opacity build-up speed
@export var spray_rate := 25.0
## Wetness build-up speed (drips)
@export var wet_rate := 1.3

var wall: GraffitiWall
var controller: XRController3D
var color := Color(0.9, 0.1, 0.1)
var nozzle_scale := 1.0
var intensity := 0.0

var _spraying := false
var _last_px := Vector2.ZERO
var _has_last := false
var _haptic_timer := 0.0
var _cap_mat: StandardMaterial3D
var _actuator: Node3D
var _cursor: MeshInstance3D
var _cursor_mat: ShaderMaterial
var _particles: GPUParticles3D
var _particle_mat: ParticleProcessMaterial
var _audio: AudioStreamPlayer3D
var _playback: AudioStreamGeneratorPlayback
var _noise_state := 0.0
var _volume := 0.0


func _ready() -> void:
	_build_model()
	_build_cursor()
	_build_particles()
	_build_audio()
	set_color(color)


func set_color(c: Color) -> void:
	color = c
	_cap_mat.albedo_color = c
	_particle_mat.color = Color(c.r, c.g, c.b, 0.35)
	_cursor_mat.set_shader_parameter("ring_color", Color(c.r, c.g, c.b, 0.85))


## Position of the nozzle tip (used to touch palette swatches).
func tip_position() -> Vector3:
	return global_transform * Vector3(0, 0, -0.01)


## Call once per frame with the current trigger value (0..1).
func update_spray(trigger: float, delta: float) -> void:
	intensity = pow(clampf((trigger - 0.05) / 0.95, 0.0, 1.0), 1.3)
	var origin := global_position
	var dir := -global_basis.z.normalized()
	var hit := wall.intersect_ray(origin, dir, max_distance) if wall else {}

	_update_cursor(hit)
	_update_effects(delta)
	_actuator.position.y = 0.006 - 0.004 * clampf(trigger, 0.0, 1.0)

	if intensity <= 0.0 or hit.is_empty():
		if _spraying:
			wall.end_stroke()
		_spraying = false
		_has_last = false
		return

	_spraying = true
	wall.ensure_stroke()
	var dist: float = hit.distance
	var radius := (base_radius + dist * spread) * nozzle_scale
	var softness := clampf(0.1 + dist * 2.2, 0.1, 1.0)
	var density := pow(reference_radius / radius, 2.0)
	var alpha_frame := 1.0 - exp(-spray_rate * intensity * delta * density)
	var ppm := wall.pixels_per_meter
	var r_px := radius * ppm
	var px: Vector2 = hit.px

	# Interpolate between frames so fast strokes stay continuous.
	var from := _last_px if _has_last else px
	var seg := px - from
	var n := clampi(ceili(seg.length() / maxf(r_px * 0.3, 0.75)), 1, 64)
	var a := alpha_frame / n
	for i in n:
		wall.stamp(from + seg * (float(i + 1) / n), r_px, softness, color, a)
	_last_px = px
	_has_last = true

	# Overspray speckles at larger distances
	if dist > 0.12:
		var dots := int(intensity * dist * 14.0 + randf())
		for i in dots:
			var off := Vector2.from_angle(randf() * TAU) * sqrt(randf_range(0.2, 1.0)) * r_px * 1.4
			wall.stamp(px + off, randf_range(0.0012, 0.0028) * ppm, 0.3, color, 0.3 * intensity)

	wall.deposit(px, radius, wet_rate * intensity * delta * density, color)


func _update_cursor(hit: Dictionary) -> void:
	if hit.is_empty():
		_cursor.visible = false
		return
	_cursor.visible = true
	var radius := (base_radius + float(hit.distance) * spread) * nozzle_scale
	var normal: Vector3 = hit.normal
	var up := Vector3.UP if absf(normal.dot(Vector3.UP)) < 0.99 else Vector3.FORWARD
	var basis := Basis.looking_at(-normal, up)
	var s := maxf(radius * 2.0, 0.01)
	_cursor.global_transform = Transform3D(basis.scaled(Vector3(s, s, 1.0)), hit.point + normal * 0.003)


func _update_effects(delta: float) -> void:
	_particles.emitting = intensity > 0.0
	_particles.amount_ratio = clampf(0.2 + intensity * 0.8, 0.0, 1.0)

	_volume = move_toward(_volume, intensity * 0.35, delta * 4.0)
	if _playback:
		var frames := _playback.get_frames_available()
		for i in frames:
			_noise_state += (randf_range(-1.0, 1.0) - _noise_state) * 0.45
			var s := _noise_state * _volume
			_playback.push_frame(Vector2(s, s))

	if controller and intensity > 0.0:
		_haptic_timer -= delta
		if _haptic_timer <= 0.0:
			_haptic_timer = 0.05
			controller.trigger_haptic_pulse("haptic", 0.0, 0.05 + 0.25 * intensity, 0.06, 0.0)


func _build_model() -> void:
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.75, 0.76, 0.78)
	metal.metallic = 0.8
	metal.roughness = 0.35

	var body := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.033
	cyl.bottom_radius = 0.033
	cyl.height = 0.17
	body.mesh = cyl
	body.material_override = metal
	body.position = Vector3(0, -0.11, 0.03)
	add_child(body)

	_cap_mat = StandardMaterial3D.new()
	_cap_mat.roughness = 0.4
	var cap := MeshInstance3D.new()
	var cap_mesh := CylinderMesh.new()
	cap_mesh.top_radius = 0.018
	cap_mesh.bottom_radius = 0.031
	cap_mesh.height = 0.022
	cap.mesh = cap_mesh
	cap.material_override = _cap_mat
	cap.position = Vector3(0, -0.014, 0.03)
	add_child(cap)

	# Nozzle button that moves with the trigger, opening points along -Z
	_actuator = Node3D.new()
	_actuator.position = Vector3(0, 0.006, 0)
	add_child(_actuator)
	var white := StandardMaterial3D.new()
	white.albedo_color = Color(0.95, 0.95, 0.95)
	var button := MeshInstance3D.new()
	var button_mesh := CylinderMesh.new()
	button_mesh.top_radius = 0.009
	button_mesh.bottom_radius = 0.009
	button_mesh.height = 0.012
	button.mesh = button_mesh
	button.material_override = white
	button.position = Vector3(0, -0.006, 0.025)
	_actuator.add_child(button)
	var nozzle := MeshInstance3D.new()
	var nozzle_mesh := BoxMesh.new()
	nozzle_mesh.size = Vector3(0.008, 0.008, 0.03)
	nozzle.mesh = nozzle_mesh
	nozzle.material_override = white
	nozzle.position = Vector3(0, -0.006, 0.012)
	_actuator.add_child(nozzle)


func _build_cursor() -> void:
	_cursor = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	_cursor.mesh = quad
	_cursor_mat = ShaderMaterial.new()
	_cursor_mat.shader = CURSOR_SHADER
	_cursor.material_override = _cursor_mat
	_cursor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_cursor.top_level = true
	_cursor.visible = false
	add_child(_cursor)


func _build_particles() -> void:
	_particles = GPUParticles3D.new()
	_particles.amount = 96
	_particles.lifetime = 0.45
	_particles.local_coords = false
	_particles.emitting = false
	_particle_mat = ParticleProcessMaterial.new()
	_particle_mat.direction = Vector3(0, 0, -1)
	_particle_mat.spread = 14.0
	_particle_mat.initial_velocity_min = 1.2
	_particle_mat.initial_velocity_max = 2.4
	_particle_mat.gravity = Vector3(0, -0.4, 0)
	_particle_mat.damping_min = 2.0
	_particle_mat.damping_max = 3.0
	_particle_mat.scale_min = 0.4
	_particle_mat.scale_max = 1.2
	var fade := Gradient.new()
	fade.set_color(0, Color(1, 1, 1, 1))
	fade.set_color(1, Color(1, 1, 1, 0))
	var ramp := GradientTexture1D.new()
	ramp.gradient = fade
	_particle_mat.color_ramp = ramp
	_particles.process_material = _particle_mat

	var quad := QuadMesh.new()
	quad.size = Vector2(0.025, 0.025)
	var mat := StandardMaterial3D.new()
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = _make_puff_texture()
	quad.material = mat
	_particles.draw_pass_1 = quad
	add_child(_particles)


func _make_puff_texture() -> Texture2D:
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 1))
	grad.set_color(1, Color(1, 1, 1, 0))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 32
	tex.height = 32
	return tex


func _build_audio() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = 22050.0
	gen.buffer_length = 0.1
	_audio = AudioStreamPlayer3D.new()
	_audio.stream = gen
	_audio.unit_size = 2.0
	add_child(_audio)
	_audio.play()
	_playback = _audio.get_stream_playback() as AudioStreamGeneratorPlayback
