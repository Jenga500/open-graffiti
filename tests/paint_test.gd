extends SceneTree
# Smoke test: spray, drip, undo, export. Run with --xr-mode off (needs a GPU, not headless).

func _initialize() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	var wall: GraffitiWall = main.get_node("GraffitiWall")
	wall.export_dir = OS.get_environment("TEST_OUT")
	var spray: SprayCan = main.get_node("XROrigin3D/RightController/SprayCan")
	main.set_process(false) # drive the can manually
	for i in 5: await process_frame
	var dt := 1.0 / 90.0
	# Stroke 1: horizontal line, 20cm away
	for i in 150:
		spray.global_transform = Transform3D(Basis(), wall.global_position + Vector3(-1.0 + i * 0.008, 1.5, 0.2))
		spray.update_spray(1.0, dt)
		await process_frame
	spray.update_spray(0.0, dt)
	# Stroke 2: hold close in one spot -> drips
	spray.set_color(Color(0.1, 0.3, 1.0))
	for i in 240:
		spray.global_transform = Transform3D(Basis(), wall.global_position + Vector3(1.0, 2.0, 0.05))
		spray.update_spray(1.0, dt)
		await process_frame
	spray.update_spray(0.0, dt)
	print("drips active: ", wall._drips.size())
	for i in 400: await process_frame
	print("undo stack: ", wall._undo_stack.size())
	await wall.export_png()
	for i in 3: await process_frame
	wall.undo()
	for i in 3: await process_frame
	await wall.export_png()
	for i in 3: await process_frame
	quit()
