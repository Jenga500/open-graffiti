class_name GraffitiWall
extends Node3D

## A paintable wall.
##
## The paint lives in an RGBA image (a SubViewport render target, premultiplied
## alpha) that is never cleared, so spray stamps accumulate on the GPU. Undo
## snapshots and the PNG export read it back as Image. The node origin is the
## bottom centre of the wall, the painted side faces +Z.

signal message(text: String)

const STAMP_SHADER := preload("res://shaders/stamp.gdshader")
const RESTORE_SHADER := preload("res://shaders/restore.gdshader")
const UNPREMULTIPLY_SHADER := preload("res://shaders/unpremultiply.gdshader")
const WALL_SHADER := preload("res://shaders/wall.gdshader")
const SOFTNESS_LEVELS := 12
const MAX_DRIPS := 64

@export var wall_size := Vector2(6.0, 3.0)
@export var pixels_per_meter := 400.0
@export var max_undo := 20
## Folder for exported PNGs. Empty = Downloads folder
@export_global_dir var export_dir := ""
## Crop the export to the painted area
@export var export_trim := false

@export_group("Drips")
## Wetness above which paint starts to run
@export var drip_threshold := 1.0
## Time constant in seconds for paint drying (wetness decay)
@export var wet_decay_time := 2.5
## Size of one wetness cell in meters
@export var wet_cell_size := 0.015

var canvas_size: Vector2i

var _canvas_vp: SubViewport
var _painter: CanvasPainter
var _restore_sprite: Sprite2D
var _export_vp: SubViewport
var _brushes: Array[Texture2D] = []
var _undo_stack: Array[Image] = []
var _stroke_open := false
var _restore_pending := false
var _restore_shown := false
var _clear_pending := false
var _exporting := false

# Wetness grid (lazy exponential decay: value * exp(-(now - time) / tau))
var _grid_size: Vector2i
var _wet := PackedFloat32Array()
var _wet_time := PackedFloat32Array()
var _time := 0.0
var _drips: Array[Drip] = []


class Drip:
	var pos: Vector2 # canvas pixels
	var volume: float # remaining run length in meters
	var speed := 0.0 # m/s
	var width: float # radius in meters
	var color: Color
	var phase: float


func _ready() -> void:
	process_priority = 100 # commit after the spray can has queued its stamps
	canvas_size = Vector2i(roundi(wall_size.x * pixels_per_meter), roundi(wall_size.y * pixels_per_meter))
	_build_brushes()
	_build_canvas()
	_build_export_viewport()
	_build_mesh()
	_build_collision()
	_grid_size = Vector2i(ceili(wall_size.x / wet_cell_size), ceili(wall_size.y / wet_cell_size))
	_reset_wetness()
	_clear_pending = true


func _process(delta: float) -> void:
	_time += delta
	_update_drips(delta)

	if _restore_shown:
		_restore_sprite.visible = false
		_restore_shown = false

	if _clear_pending or _restore_pending or _painter.has_pending():
		# Whenever the canvas renders, the painter must contain only new stamps.
		_painter.commit()
		if _clear_pending:
			_canvas_vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
			_clear_pending = false
		if _restore_pending:
			_restore_sprite.visible = true
			_restore_shown = true
			_restore_pending = false
		_canvas_vp.render_target_update_mode = SubViewport.UPDATE_ONCE


#region Painting API

## Intersects a ray with the wall. Returns {} on miss, else point, normal, distance, px.
func intersect_ray(origin: Vector3, dir: Vector3, max_distance: float) -> Dictionary:
	var inv := global_transform.affine_inverse()
	var lo := inv * origin
	var ld := (inv.basis * dir).normalized()
	if lo.z < -0.02 or ld.z > -0.0001:
		return {}
	var t := maxf(lo.z, 0.0) / -ld.z
	if t > max_distance:
		return {}
	var hp := lo + ld * t
	hp.z = 0.0
	var margin := 0.3
	if absf(hp.x) > wall_size.x * 0.5 + margin or hp.y < -margin or hp.y > wall_size.y + margin:
		return {}
	return {
		"point": global_transform * hp,
		"normal": global_basis.z.normalized(),
		"distance": maxf(lo.z, 0.0) / -ld.z,
		"px": local_to_canvas(hp),
	}


func local_to_canvas(p: Vector3) -> Vector2:
	return Vector2((p.x + wall_size.x * 0.5) * pixels_per_meter, (wall_size.y - p.y) * pixels_per_meter)


## Queues one soft round stamp. radius_px in canvas pixels, softness 0 (hard) .. 1 (soft).
func stamp(px: Vector2, radius_px: float, softness: float, color: Color, alpha: float) -> void:
	if alpha <= 0.0005:
		return
	var r := maxf(radius_px, 0.75)
	var tex := _brushes[clampi(roundi(softness * (SOFTNESS_LEVELS - 1)), 0, SOFTNESS_LEVELS - 1)]
	_painter.add_stamp(tex, Rect2(px - Vector2(r, r), Vector2(r, r) * 2.0), Color(color.r, color.g, color.b, alpha))


## Adds wet paint around px (amount in threshold units). Spawns drips when too wet.
func deposit(px: Vector2, radius_m: float, amount: float, color: Color) -> void:
	var cell_px := wet_cell_size * pixels_per_meter
	var core_px := maxf(radius_m * 0.6 * pixels_per_meter, cell_px * 0.5)
	var c0 := Vector2i(floori((px.x - core_px) / cell_px), floori((px.y - core_px) / cell_px))
	var c1 := Vector2i(floori((px.x + core_px) / cell_px), floori((px.y + core_px) / cell_px))
	c0 = c0.clamp(Vector2i.ZERO, _grid_size - Vector2i.ONE)
	c1 = c1.clamp(Vector2i.ZERO, _grid_size - Vector2i.ONE)
	for cy in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			var centre := (Vector2(cx, cy) + Vector2(0.5, 0.5)) * cell_px
			var d := centre.distance_to(px) / core_px
			if d > 1.0:
				continue
			var idx := cy * _grid_size.x + cx
			var w := _wet_value(idx) + amount * (1.0 - d * d)
			_wet[idx] = w
			_wet_time[idx] = _time
			if w > drip_threshold:
				_spawn_drip(cx, cy, w, color)


## Opens an undo step if none is open (call every frame while spraying).
func ensure_stroke() -> void:
	if _stroke_open:
		return
	_stroke_open = true
	_push_undo()


func end_stroke() -> void:
	_stroke_open = false


func undo() -> void:
	_stroke_open = false
	if _undo_stack.is_empty():
		message.emit("Nichts zum Rückgängigmachen")
		return
	_cancel_wet_paint()
	_restore_sprite.texture = ImageTexture.create_from_image(_undo_stack.pop_back())
	_restore_pending = true
	message.emit("Rückgängig (%d übrig)" % _undo_stack.size())


func clear_wall() -> void:
	_stroke_open = false
	_push_undo()
	_cancel_wet_paint()
	_clear_pending = true
	message.emit("Wand geleert (Undo möglich)")


func export_png() -> void:
	if _exporting:
		return
	_exporting = true
	_export_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	var img := _export_vp.get_texture().get_image()
	_exporting = false
	if img == null:
		message.emit("Export fehlgeschlagen: kein Bild")
		return
	if export_trim:
		var used := img.get_used_rect()
		if used.size.x == 0 or used.size.y == 0:
			message.emit("Wand ist leer – nichts exportiert")
			return
		img = img.get_region(used)
	var dir := get_export_dir()
	var err := DirAccess.make_dir_recursive_absolute(dir)
	if err != OK:
		message.emit("Ordner nicht anlegbar: %s" % dir)
		return
	var stamp_str := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var path := dir.path_join("graffiti_%s.png" % stamp_str)
	var n := 2
	while FileAccess.file_exists(path):
		path = dir.path_join("graffiti_%s_%d.png" % [stamp_str, n])
		n += 1
	err = img.save_png(path)
	if err != OK:
		message.emit("Export fehlgeschlagen (%s)" % error_string(err))
		return
	print("Exported graffiti to ", path)
	message.emit("Exportiert:\n%s" % path)


func get_export_dir() -> String:
	if not export_dir.is_empty():
		return export_dir
	var downloads := OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS)
	if downloads.is_empty():
		downloads = OS.get_environment("HOME").path_join("Downloads")
	return downloads

#endregion


#region Internals

func _push_undo() -> void:
	var img := _canvas_vp.get_texture().get_image()
	if img == null:
		img = Image.create_empty(canvas_size.x, canvas_size.y, false, Image.FORMAT_RGBA8)
	_undo_stack.append(img)
	while _undo_stack.size() > max_undo:
		_undo_stack.pop_front()


func _cancel_wet_paint() -> void:
	_drips.clear()
	_painter.discard_pending()
	_reset_wetness()


func _reset_wetness() -> void:
	var n := _grid_size.x * _grid_size.y
	_wet.resize(n)
	_wet.fill(0.0)
	_wet_time.resize(n)
	_wet_time.fill(0.0)


func _wet_value(idx: int) -> float:
	return _wet[idx] * exp(-(_time - _wet_time[idx]) / wet_decay_time)


func _spawn_drip(cx: int, cy: int, wetness: float, color: Color) -> void:
	# Drain the neighbourhood so one blob produces one drip.
	for x in range(maxi(cx - 1, 0), mini(cx + 2, _grid_size.x)):
		for y in range(maxi(cy - 1, 0), mini(cy + 2, _grid_size.y)):
			var idx := y * _grid_size.x + x
			_wet[idx] = minf(_wet_value(idx), drip_threshold * 0.35)
			_wet_time[idx] = _time
	if _drips.size() >= MAX_DRIPS:
		return
	var cell_px := wet_cell_size * pixels_per_meter
	var d := Drip.new()
	d.pos = Vector2((cx + randf_range(0.25, 0.75)) * cell_px, (cy + 0.9) * cell_px)
	var excess := wetness - drip_threshold
	d.volume = clampf(0.06 + excess * 0.5 + randf() * 0.06, 0.04, 0.45)
	d.width = randf_range(0.0022, 0.0035) + minf(excess, 1.0) * 0.0015
	d.color = color
	d.phase = randf() * TAU
	_drips.append(d)


func _update_drips(delta: float) -> void:
	if _drips.is_empty():
		return
	var bottom := float(canvas_size.y)
	for i in range(_drips.size() - 1, -1, -1):
		var d := _drips[i]
		var target_speed := lerpf(0.02, 0.16, clampf(d.volume / 0.3, 0.0, 1.0))
		d.speed = move_toward(d.speed, target_speed, delta * 0.5)
		var dy := d.speed * delta * pixels_per_meter
		var r_px := d.width * (0.65 + 0.35 * clampf(d.volume / 0.08, 0.0, 1.0)) * pixels_per_meter
		var steps := maxi(ceili(dy / maxf(r_px * 0.5, 0.5)), 1)
		var start := d.pos
		d.phase += delta * 1.7
		var end := start + Vector2(sin(d.phase) * 0.05 * dy, dy)
		for s in steps:
			stamp(start.lerp(end, float(s + 1) / steps), r_px, 0.15, d.color, 0.8)
		d.pos = end
		d.volume -= d.speed * delta
		if d.volume <= 0.0 or d.pos.y >= bottom:
			# Droplet at the end of the run
			stamp(d.pos + Vector2(0, r_px * 0.6), r_px * 1.5, 0.2, d.color, 0.95)
			_drips.remove_at(i)


func _build_brushes() -> void:
	for level in SOFTNESS_LEVELS:
		var softness := float(level) / (SOFTNESS_LEVELS - 1)
		var core := 1.0 - lerpf(0.08, 1.0, softness)
		var grad := Gradient.new()
		var offsets := PackedFloat32Array()
		var colors := PackedColorArray()
		offsets.append(0.0)
		colors.append(Color(1, 1, 1, 1))
		const STEPS := 10
		for s in range(STEPS + 1):
			var t := float(s) / STEPS
			# Gaussian-like falloff that reaches exactly 0 at the rim
			var a := (exp(-4.0 * t * t) - exp(-4.0)) / (1.0 - exp(-4.0))
			offsets.append(core + (1.0 - core) * t)
			colors.append(Color(1, 1, 1, a))
		grad.offsets = offsets
		grad.colors = colors
		var tex := GradientTexture2D.new()
		tex.gradient = grad
		tex.fill = GradientTexture2D.FILL_RADIAL
		tex.fill_from = Vector2(0.5, 0.5)
		tex.fill_to = Vector2(1.0, 0.5)
		tex.width = 128
		tex.height = 128
		_brushes.append(tex)


func _build_canvas() -> void:
	_canvas_vp = SubViewport.new()
	_canvas_vp.name = "PaintCanvas"
	_canvas_vp.size = canvas_size
	_canvas_vp.transparent_bg = true
	_canvas_vp.disable_3d = true
	_canvas_vp.render_target_clear_mode = SubViewport.CLEAR_MODE_NEVER
	_canvas_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_canvas_vp)

	_restore_sprite = Sprite2D.new()
	_restore_sprite.centered = false
	_restore_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_restore_sprite.visible = false
	var restore_mat := ShaderMaterial.new()
	restore_mat.shader = RESTORE_SHADER
	_restore_sprite.material = restore_mat
	_canvas_vp.add_child(_restore_sprite)

	_painter = CanvasPainter.new()
	_painter.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	var stamp_mat := ShaderMaterial.new()
	stamp_mat.shader = STAMP_SHADER
	_painter.material = stamp_mat
	_canvas_vp.add_child(_painter)


func _build_export_viewport() -> void:
	_export_vp = SubViewport.new()
	_export_vp.name = "ExportCanvas"
	_export_vp.size = canvas_size
	_export_vp.transparent_bg = true
	_export_vp.disable_3d = true
	_export_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_export_vp)
	var sprite := Sprite2D.new()
	sprite.centered = false
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.texture = _canvas_vp.get_texture()
	var mat := ShaderMaterial.new()
	mat.shader = UNPREMULTIPLY_SHADER
	sprite.material = mat
	_export_vp.add_child(sprite)


func _build_mesh() -> void:
	var mesh := QuadMesh.new()
	mesh.size = wall_size
	var mat := ShaderMaterial.new()
	mat.shader = WALL_SHADER
	mat.set_shader_parameter("paint_tex", _canvas_vp.get_texture())
	mat.set_shader_parameter("wall_size", wall_size)
	var mi := MeshInstance3D.new()
	mi.name = "WallMesh"
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = Vector3(0, wall_size.y * 0.5, 0)
	add_child(mi)

	# Simple frame/back so the wall reads as a solid object
	var back := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(wall_size.x + 0.1, wall_size.y + 0.05, 0.25)
	back.mesh = box
	var back_mat := StandardMaterial3D.new()
	back_mat.albedo_color = Color(0.35, 0.34, 0.33)
	back_mat.roughness = 1.0
	back.material_override = back_mat
	back.position = Vector3(0, (wall_size.y + 0.05) * 0.5, -0.126)
	add_child(back)


func _build_collision() -> void:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(wall_size.x + 0.1, wall_size.y, 0.25)
	shape.shape = box
	shape.position = Vector3(0, wall_size.y * 0.5, -0.126)
	body.add_child(shape)
	add_child(body)

#endregion
