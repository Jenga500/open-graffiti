class_name CanvasPainter
extends Node2D

## Collects spray stamps for one frame and draws them into the paint canvas.
##
## The canvas viewport never clears, so whatever is drawn here is accumulated.
## The wall only renders the viewport in frames where commit() was called, which
## guarantees that every stamp is drawn exactly once.

# Stamps queued during the current frame: [texture, rect, color]
var _pending: Array = []
# Stamps that the next viewport render will draw
var _drawn: Array = []


func add_stamp(texture: Texture2D, rect: Rect2, color: Color) -> void:
	_pending.append([texture, rect, color])


func has_pending() -> bool:
	return not _pending.is_empty()


func discard_pending() -> void:
	_pending.clear()


## Moves the pending stamps into the draw list (must be followed by a viewport render).
func commit() -> void:
	_drawn = _pending
	_pending = []
	queue_redraw()


func _draw() -> void:
	for s in _drawn:
		draw_texture_rect(s[0], s[1], false, s[2])
