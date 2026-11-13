## Autoload injected by Godot MCP Pro plugin at runtime.
## Monitors for screenshot requests from the editor and captures the game viewport.
extends Node

const REQUEST_PATH := "user://mcp_screenshot_request"
const SCREENSHOT_PATH := "user://mcp_screenshot.png"


func _ready() -> void:
	# Dev tooling: there is no editor in an exported build. Free before any
	# per-frame work is registered, so a player build pays nothing for this.
	# plugin.gd takes the [autoload] entry out of every export (MCPExportFilter),
	# so this node normally does not exist there at all. The check stays for a
	# project that is exported without the editor plugin running while its
	# project.godot still lists the entry: the script then has to ship (an
	# autoload pointing at a missing script errors on startup) and end itself.
	if not OS.has_feature("editor"):
		queue_free()
		return
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(_delta: float) -> void:
	if FileAccess.file_exists(REQUEST_PATH):
		_take_screenshot()


func _take_screenshot() -> void:
	# Delete request file immediately to avoid re-triggering
	DirAccess.remove_absolute(REQUEST_PATH)

	# Wait one frame so the viewport has a fully rendered image
	# process_always=true (default) so the timer ticks even when tree is paused
	await get_tree().create_timer(0.05).timeout

	var viewport := get_viewport()
	if viewport == null:
		return

	var image := viewport.get_texture().get_image()
	if image == null:
		return

	image.save_png(SCREENSHOT_PATH)
