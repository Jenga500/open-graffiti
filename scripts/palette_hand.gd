class_name PaletteHand
extends Node3D

## Colour palette and nozzle (cap) selection floating above the left hand.
##
## Select by touching a swatch or cap with the tip of the spray can, or step
## through them with the controller buttons (see main.gd).

signal color_changed(color: Color)
signal nozzle_changed(scale: float, cap_name: String)

const COLORS: Array[Color] = [
	Color(0.95, 0.95, 0.95), Color(0.05, 0.05, 0.05), Color(0.5, 0.5, 0.52), Color(0.45, 0.25, 0.1),
	Color(0.9, 0.08, 0.08), Color(1.0, 0.45, 0.0), Color(1.0, 0.85, 0.0), Color(0.6, 0.9, 0.05),
	Color(0.05, 0.65, 0.2), Color(0.0, 0.6, 0.55), Color(0.0, 0.8, 1.0), Color(0.1, 0.25, 0.9),
	Color(0.45, 0.1, 0.75), Color(0.95, 0.1, 0.65), Color(1.0, 0.6, 0.75), Color(0.85, 0.75, 0.55),
]
const NOZZLES := [
	["Skinny", 0.45],
	["Outline", 0.7],
	["Standard", 1.0],
	["Fat", 1.6],
	["Super Fat", 2.4],
]
const COLUMNS := 4
const SPACING := 0.032
const TOUCH_RADIUS := 0.02

var color_index := 4
var nozzle_index := 2

var _swatches: Array[MeshInstance3D] = []
var _caps: Array[MeshInstance3D] = []
var _color_frame: MeshInstance3D
var _cap_frame: MeshInstance3D
var _info_label: Label3D
var _status_label: Label3D
var _status_time := 0.0
var _last_touch := ""


func _ready() -> void:
	_build()
	select_color(color_index)
	select_nozzle(nozzle_index)


func _process(delta: float) -> void:
	if _status_time > 0.0:
		_status_time -= delta
		_status_label.modulate.a = clampf(_status_time, 0.0, 1.0)


func current_color() -> Color:
	return COLORS[color_index]


func current_nozzle_scale() -> float:
	return NOZZLES[nozzle_index][1]


func select_color(i: int) -> void:
	color_index = posmod(i, COLORS.size())
	_color_frame.position = _swatches[color_index].position + Vector3(0, 0, -0.002)
	_update_info()
	color_changed.emit(COLORS[color_index])


func step_color(dir: int) -> void:
	select_color(color_index + dir)


func select_nozzle(i: int) -> void:
	nozzle_index = clampi(i, 0, NOZZLES.size() - 1)
	_cap_frame.position = _caps[nozzle_index].position + Vector3(0, 0, -0.002)
	_update_info()
	nozzle_changed.emit(NOZZLES[nozzle_index][1], NOZZLES[nozzle_index][0])


func step_nozzle(dir: int) -> void:
	select_nozzle(nozzle_index + dir)


## Selects whatever swatch/cap the point touches. Returns true on a new selection.
func try_touch(global_point: Vector3) -> bool:
	if not is_visible_in_tree():
		return false
	var p := to_local(global_point)
	var touched := ""
	for i in _swatches.size():
		if p.distance_to(_swatches[i].position) < TOUCH_RADIUS:
			touched = "c%d" % i
			if touched != _last_touch:
				select_color(i)
	for i in _caps.size():
		if p.distance_to(_caps[i].position) < TOUCH_RADIUS:
			touched = "n%d" % i
			if touched != _last_touch:
				select_nozzle(i)
	var is_new := not touched.is_empty() and touched != _last_touch
	_last_touch = touched
	return is_new


func show_status(text: String, duration := 3.0) -> void:
	_status_label.text = text
	_status_time = duration
	_status_label.modulate.a = 1.0


func _update_info() -> void:
	if _info_label:
		_info_label.text = "Düse: %s" % NOZZLES[nozzle_index][0]


func _build() -> void:
	var rows := ceili(float(COLORS.size()) / COLUMNS)
	var panel_w := COLUMNS * SPACING + 0.02
	var panel_h := (rows + 1) * SPACING + 0.05

	var panel := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(panel_w, panel_h)
	panel.mesh = quad
	var panel_mat := StandardMaterial3D.new()
	panel_mat.albedo_color = Color(0.08, 0.08, 0.09, 0.85)
	panel_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	panel_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	panel.material_override = panel_mat
	panel.position = Vector3(0, -panel_h * 0.5 + 0.015, -0.006)
	add_child(panel)

	var swatch_mesh := BoxMesh.new()
	swatch_mesh.size = Vector3(0.024, 0.024, 0.008)
	for i in COLORS.size():
		var m := MeshInstance3D.new()
		m.mesh = swatch_mesh
		var mat := StandardMaterial3D.new()
		mat.albedo_color = COLORS[i]
		mat.roughness = 0.5
		m.material_override = mat
		var col := i % COLUMNS
		var row := i / COLUMNS
		m.position = Vector3((col - (COLUMNS - 1) * 0.5) * SPACING, -row * SPACING, 0)
		add_child(m)
		_swatches.append(m)

	var nozzle_y := -rows * SPACING - 0.006
	var cap_mat := StandardMaterial3D.new()
	cap_mat.albedo_color = Color(0.92, 0.92, 0.92)
	for i in NOZZLES.size():
		var m := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		var r: float = 0.003 + 0.0035 * float(NOZZLES[i][1])
		cyl.top_radius = r
		cyl.bottom_radius = r
		cyl.height = 0.008
		m.mesh = cyl
		m.material_override = cap_mat
		m.rotation_degrees = Vector3(90, 0, 0)
		m.position = Vector3((i - (NOZZLES.size() - 1) * 0.5) * 0.028, nozzle_y, 0)
		add_child(m)
		_caps.append(m)

	_color_frame = _make_frame(Vector2(0.031, 0.031))
	_cap_frame = _make_frame(Vector2(0.027, 0.027))

	var title := Label3D.new()
	title.text = "PALETTE"
	title.pixel_size = 0.0004
	title.font_size = 32
	title.position = Vector3(0, 0.03, 0)
	add_child(title)

	_info_label = Label3D.new()
	_info_label.pixel_size = 0.0004
	_info_label.font_size = 28
	_info_label.position = Vector3(0, nozzle_y - 0.022, 0)
	add_child(_info_label)

	_status_label = Label3D.new()
	_status_label.pixel_size = 0.0004
	_status_label.font_size = 26
	_status_label.width = 600
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.modulate = Color(1, 0.9, 0.4, 0)
	_status_label.position = Vector3(0, 0.065, 0)
	add_child(_status_label)


func _make_frame(size: Vector2) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = size
	m.mesh = quad
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1, 1, 1)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.material_override = mat
	add_child(m)
	return m
