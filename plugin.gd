@tool
extends EditorPlugin

const _MCP_AUTOLOADS: Array[Array] = [
	["autoload/MCPScreenshot", "res://addons/godot_mcp/mcp_screenshot_service.gd"],
	["autoload/MCPInputService", "res://addons/godot_mcp/mcp_input_service.gd"],
	["autoload/MCPGameInspector", "res://addons/godot_mcp/mcp_game_inspector_service.gd"],
]

const _MCP_TEMP_FILES: Array[String] = [
	"mcp_game_request",
	"mcp_game_response",
	"mcp_input_commands",
	"mcp_screenshot_request",
]

var websocket_server: Node
var command_router: Node
var status_panel: Control
var auto_dismiss_dialogs: bool = false
# Track which autoloads THIS session injected (vs project-owned)
var _session_injected_autoloads: Array[String] = []
var _export_filter: MCPExportFilter


# Keeps the MCP runtime services out of exported projects.
#
# The services are development tools: they answer this editor plugin through
# files in the user data folder, which only works for a game started from the
# editor. An exported build has no editor to talk to. Their autoload entries
# live in the project settings (injected below, and written to project.godot
# while the editor runs), and an export stores the project settings that are in
# memory at that moment. So the entries are taken out when an export begins and
# put back when it ends. Nothing is saved in between: project.godot and the
# editor's own state are the same before and after.
class MCPExportFilter extends EditorExportPlugin:
	# [setting name, value, position in the autoload order] of each entry taken out.
	var _removed: Array[Array] = []


	func _get_name() -> String:
		return "MCPExportFilter"


	func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
		_removed.clear()
		for entry: Array in _MCP_AUTOLOADS:
			var key: String = entry[0]
			if not ProjectSettings.has_setting(key):
				continue
			var value: String = ProjectSettings.get_setting(key)
			# Only the services themselves: a project may use one of these
			# names for an autoload of its own.
			if _autoload_path(value) != entry[1]:
				continue
			_removed.append([key, value, ProjectSettings.get_order(key)])
			ProjectSettings.set_setting(key, null)


	func _export_end() -> void:
		for entry: Array in _removed:
			ProjectSettings.set_setting(entry[0], entry[1])
			ProjectSettings.set_order(entry[0], entry[2])
		_removed.clear()


	# The script or scene an autoload entry points at ("*res://..." or "*uid://...").
	static func _autoload_path(value: String) -> String:
		var path := value.trim_prefix("*")
		if path.begins_with("uid://"):
			var id := ResourceUID.text_to_id(path)
			if ResourceUID.has_id(id):
				path = ResourceUID.get_id_path(id)
		return path


func _enter_tree() -> void:
	# Create command router
	command_router = preload("res://addons/godot_mcp/command_router.gd").new()
	command_router.name = "MCPCommandRouter"
	command_router.editor_plugin = self
	add_child(command_router)

	# Create WebSocket server
	websocket_server = preload("res://addons/godot_mcp/websocket_server.gd").new()
	websocket_server.name = "MCPWebSocketServer"
	websocket_server.command_router = command_router
	add_child(websocket_server)

	# Create status panel
	var panel_scene: PackedScene = preload("res://addons/godot_mcp/ui/status_panel.tscn")
	status_panel = panel_scene.instantiate()
	add_control_to_bottom_panel(status_panel, "MCP Pro")
	status_panel.call_deferred("setup", websocket_server, command_router)

	# Inject MCP autoloads into project settings
	_inject_autoloads()

	# ...and keep them out of every export (see MCPExportFilter).
	# The cast works around https://github.com/godotengine/godot/issues/73525
	_export_filter = (MCPExportFilter as Variant).new()
	add_export_plugin(_export_filter)

	websocket_server.start_server()
	var cfg := ConfigFile.new()
	var ver := "unknown"
	if cfg.load("res://addons/godot_mcp/plugin.cfg") == OK:
		ver = cfg.get_value("plugin", "version", "unknown")
	print("[MCP] Godot MCP Pro v%s started (ports %d-%d)" % [ver, websocket_server.base_port, websocket_server.max_port])


func _exit_tree() -> void:
	if _export_filter:
		remove_export_plugin(_export_filter)
		_export_filter = null

	# Remove MCP autoloads and clean up temp files
	_remove_autoloads()
	_cleanup_temp_files()

	if websocket_server:
		websocket_server.stop_server()

	if status_panel:
		remove_control_from_bottom_panel(status_panel)
		status_panel.queue_free()

	if command_router:
		command_router.queue_free()

	if websocket_server:
		websocket_server.queue_free()

	print("[MCP] Godot MCP Pro stopped")


func _inject_autoloads() -> void:
	_session_injected_autoloads.clear()
	var changed := false
	for entry: Array in _MCP_AUTOLOADS:
		var key: String = entry[0]
		var script: String = entry[1]
		if not ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, "*" + script)
			_session_injected_autoloads.append(key)
			changed = true
	if changed:
		ProjectSettings.save()


func _remove_autoloads() -> void:
	# Only remove autoloads that THIS session injected.
	# Pre-existing project-owned autoloads are preserved.
	var changed := false
	for key: String in _session_injected_autoloads:
		if ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, null)
			changed = true
	_session_injected_autoloads.clear()
	if changed:
		ProjectSettings.save()


var _dialog_check_timer: float = 0.0
const _DIALOG_CHECK_INTERVAL: float = 0.5  # Check every 0.5 seconds

func _process(delta: float) -> void:
	# Check if game inspector requested debugger continue
	var flag_path := OS.get_user_data_dir() + "/mcp_debugger_continue"
	if FileAccess.file_exists(flag_path):
		DirAccess.remove_absolute(flag_path)
		_try_debugger_continue()

	# Periodically check for blocking editor dialogs (only when enabled by AI)
	if auto_dismiss_dialogs:
		_dialog_check_timer += delta
		if _dialog_check_timer >= _DIALOG_CHECK_INTERVAL:
			_dialog_check_timer = 0.0
			_auto_dismiss_dialogs()


func _try_debugger_continue() -> void:
	# Last resort: find and press the debugger Continue button to unstick the game
	var base: Node = EditorInterface.get_base_control()
	var continue_btn := _find_debugger_continue_button(base)
	if continue_btn and continue_btn.visible and not continue_btn.disabled:
		continue_btn.emit_signal("pressed")
		push_warning("[MCP] Auto-pressed debugger Continue button")
	else:
		push_warning("[MCP] Could not find debugger Continue button")


func _find_debugger_continue_button(node: Node) -> Button:
	# Search for the Continue button in ScriptEditorDebugger.
	# The editor UI is translated, so matching tooltip/label text fails for
	# non-English editors (issue #34: Italian → "Continua"). Match by the editor
	# theme icon "DebugContinue" first, falling back to English text.
	var continue_icon: Texture2D = null
	var base: Control = EditorInterface.get_base_control()
	if base != null and base.has_theme_icon("DebugContinue", "EditorIcons"):
		continue_icon = base.get_theme_icon("DebugContinue", "EditorIcons")
	return _find_continue_button_recursive(node, continue_icon)


func _find_continue_button_recursive(node: Node, continue_icon: Texture2D) -> Button:
	if node is Button:
		var btn: Button = node
		if continue_icon != null and btn.icon == continue_icon:
			return btn
		if btn.tooltip_text.contains("Continue") or btn.text == "Continue":
			return btn
	for child in node.get_children():
		var found: Button = _find_continue_button_recursive(child, continue_icon)
		if found:
			return found
	return null


func _auto_dismiss_dialogs() -> void:
	var base: Node = EditorInterface.get_base_control()
	if not base:
		return
	_find_and_dismiss_dialogs(base)


func _find_and_dismiss_dialogs(node: Node) -> void:
	if node is AcceptDialog and node.visible:
		var dialog: AcceptDialog = node
		# Never dismiss file dialogs or non-modal popups
		if dialog is FileDialog:
			return
		if not dialog.exclusive:
			return
		# Get dialog title/text for logging
		var title := dialog.title
		var text := dialog.dialog_text
		# Accept the dialog (presses OK / confirms)
		dialog.get_ok_button().emit_signal("pressed")
		push_warning("[MCP] Auto-dismissed editor dialog: '%s' — %s" % [title, text])
		return  # One dialog per check cycle to avoid side effects

	for child in node.get_children():
		# Only search visible Windows to keep the scan lightweight
		if child is Window and not child.visible:
			continue
		_find_and_dismiss_dialogs(child)


func _cleanup_temp_files() -> void:
	var user_dir := OS.get_user_data_dir()
	for filename: String in _MCP_TEMP_FILES:
		var path := user_dir + "/" + filename
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	# Also clean up screenshot image
	var screenshot_path := user_dir + "/mcp_screenshot.png"
	if FileAccess.file_exists(screenshot_path):
		DirAccess.remove_absolute(screenshot_path)
