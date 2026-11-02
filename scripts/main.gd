extends Node3D

## Wires controllers, spray can, palette and wall together.
##
## VR controls:
##   Right trigger     spray (pressure = flow)
##   Right stick       X: smooth turn, Y: nozzle size up/down
##   Right B           undo
##   Right A (hold 1s) clear wall
##   Left stick        smooth locomotion
##   Left trigger      next colour, left grip: previous colour
##   Left X            undo, left Y: export PNG
##   Touch a swatch/cap on the palette with the can tip to select it.
##
## Without a headset a desktop fallback is used (see _desktop_help()).

const CLEAR_HOLD_TIME := 1.0

@onready var wall: GraffitiWall = $GraffitiWall
@onready var xr_origin: XROrigin3D = $XROrigin3D
@onready var left: XRController3D = $XROrigin3D/LeftController
@onready var right: XRController3D = $XROrigin3D/RightController
@onready var spray: SprayCan = $XROrigin3D/RightController/SprayCan
@onready var palette: PaletteHand = $XROrigin3D/LeftController/Palette

var _xr := false
var _clear_hold := -1.0
var _stick_armed := true
var _left_trigger_down := false
var _left_grip_down := false

# Desktop fallback
var _desktop_cam: Camera3D
var _hud: Label
var _hud_status: Label
var _status_time := 0.0
var _desk_distance := 0.15


func _ready() -> void:
	spray.wall = wall
	spray.controller = right
	palette.color_changed.connect(spray.set_color)
	palette.nozzle_changed.connect(_on_nozzle_changed)
	spray.set_color(palette.current_color())
	spray.nozzle_scale = palette.current_nozzle_scale()
	wall.message.connect(_show_status)

	right.button_pressed.connect(_on_right_pressed)
	right.button_released.connect(_on_right_released)
	left.button_pressed.connect(_on_left_pressed)

	var xr_interface := XRServer.find_interface("OpenXR")
	_xr = xr_interface != null and xr_interface.is_initialized()
	if not _xr:
		_enable_desktop()


func _process(delta: float) -> void:
	if _xr:
		_process_xr(delta)
	else:
		_process_desktop(delta)

	if _clear_hold >= 0.0:
		_clear_hold += delta
		if _clear_hold >= CLEAR_HOLD_TIME:
			_clear_hold = -1.0
			wall.clear_wall()

	if _status_time > 0.0:
		_status_time -= delta
		if _hud_status:
			_hud_status.modulate.a = clampf(_status_time, 0.0, 1.0)


func _process_xr(delta: float) -> void:
	spray.update_spray(right.get_float("trigger"), delta)
	palette.try_touch(spray.tip_position())

	# Right stick Y steps the nozzle size (X is used by smooth turn)
	var stick_y := right.get_vector2("primary").y
	if _stick_armed and absf(stick_y) > 0.7:
		_stick_armed = false
		palette.step_nozzle(1 if stick_y > 0.0 else -1)
	elif absf(stick_y) < 0.3:
		_stick_armed = true

	# Left trigger / grip step through colours (edge-triggered on the analog value)
	var lt := left.get_float("trigger") > 0.6
	if lt and not _left_trigger_down:
		palette.step_color(1)
	_left_trigger_down = lt
	var lg := left.get_float("grip") > 0.6
	if lg and not _left_grip_down:
		palette.step_color(-1)
	_left_grip_down = lg


func _on_right_pressed(action: String) -> void:
	match action:
		"by_button":
			wall.undo()
		"ax_button":
			_clear_hold = 0.0
			_show_status("Halten zum Leeren …", CLEAR_HOLD_TIME)


func _on_right_released(action: String) -> void:
	if action == "ax_button" and _clear_hold >= 0.0:
		_clear_hold = -1.0
		_show_status("Leeren abgebrochen", 1.0)


func _on_left_pressed(action: String) -> void:
	match action:
		"ax_button":
			wall.undo()
		"by_button":
			_show_status("Exportiere …", 2.0)
			wall.export_png()


func _on_nozzle_changed(scale: float, cap_name: String) -> void:
	spray.nozzle_scale = scale
	_show_status("Düse: %s" % cap_name, 1.5)


func _show_status(text: String, duration := 3.0) -> void:
	print(text)
	palette.show_status(text, duration)
	if _hud_status:
		_hud_status.text = text
		_hud_status.modulate.a = 1.0
	_status_time = duration


#region Desktop fallback

func _enable_desktop() -> void:
	print("No XR headset active – using desktop mode")
	left.visible = false
	_desktop_cam = Camera3D.new()
	add_child(_desktop_cam)
	_desktop_cam.position = Vector3(0, 1.6, wall.position.z + 2.2)
	_desktop_cam.look_at(wall.global_position + Vector3(0, 1.5, 0))
	_desktop_cam.current = true

	var layer := CanvasLayer.new()
	add_child(layer)
	_hud = Label.new()
	_hud.position = Vector2(16, 16)
	_hud.add_theme_color_override("font_outline_color", Color.BLACK)
	_hud.add_theme_constant_override("outline_size", 6)
	layer.add_child(_hud)
	_hud_status = Label.new()
	_hud_status.position = Vector2(16, 250)
	_hud_status.add_theme_color_override("font_color", Color(1, 0.9, 0.4))
	_hud_status.add_theme_color_override("font_outline_color", Color.BLACK)
	_hud_status.add_theme_constant_override("outline_size", 6)
	layer.add_child(_hud_status)


func _desktop_help() -> String:
	return ("DESKTOP-MODUS (kein Headset)\n"
		+ "LMB sprühen (Shift = halber Druck)\n"
		+ "Mausrad: Abstand zur Wand  (%.0f cm)\n" % (_desk_distance * 100.0)
		+ "Q / E: Farbe   F / R: Düse (%s)\n" % PaletteHand.NOZZLES[palette.nozzle_index][0]
		+ "Strg+Z: Undo   Entf: Wand leeren   P: PNG-Export")


func _process_desktop(delta: float) -> void:
	_hud.text = _desktop_help()
	var mouse := get_viewport().get_mouse_position()
	var origin := _desktop_cam.project_ray_origin(mouse)
	var dir := _desktop_cam.project_ray_normal(mouse)
	var hit := wall.intersect_ray(origin, dir, 100.0)
	var trigger := 0.0
	if not hit.is_empty():
		# Put the can at the virtual spray distance in front of the wall
		var normal: Vector3 = hit.normal
		var nozzle: Vector3 = hit.point + normal * _desk_distance
		spray.global_transform = Transform3D(Basis.looking_at(-normal, Vector3.UP), nozzle)
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			trigger = 0.5 if Input.is_key_pressed(KEY_SHIFT) else 1.0
	spray.update_spray(trigger, delta)


func _unhandled_input(event: InputEvent) -> void:
	if _xr:
		return
	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_desk_distance = clampf(_desk_distance - 0.01, 0.01, 0.9)
			MOUSE_BUTTON_WHEEL_DOWN:
				_desk_distance = clampf(_desk_distance + 0.01, 0.01, 0.9)
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_Q:
				palette.step_color(-1)
			KEY_E:
				palette.step_color(1)
			KEY_F:
				palette.step_nozzle(-1)
			KEY_R:
				palette.step_nozzle(1)
			KEY_Z:
				if event.ctrl_pressed:
					wall.undo()
			KEY_DELETE:
				wall.clear_wall()
			KEY_P:
				wall.export_png()

#endregion
