tool
class_name ConceptNode
extends GraphNode

"""
The base class for every nodes you can add in the Graph editor. It provides a basic UI framework
for nodes with simple parameters as well as a caching system and other utilities.
"""


signal delete_node
signal node_changed
signal connection_changed
signal input_changed
signal all_inputs_ready
signal output_ready


var unique_id := "concept_node"
var display_name := "ConceptNode"
var category := "No category"
var description := "A brief description of the node functionality"
var node_pool: ConceptGraphNodePool # Injected from template
var thread_pool: ConceptGraphThreadPool # Injected from template
var output := []

var _inputs := {}
var _outputs := {}
var _hboxes := []
var _resize_timer := Timer.new()
var _initialized := false	# True when all enter_tree initialization is done
var _generation_requested := false # True after calling prepare_output once
var _output_ready := false # True when the background generation was completed


func _enter_tree() -> void:
	if _initialized:
		return

	_generate_default_gui()
	_setup_slots()

	_resize_timer.one_shot = true
	_resize_timer.autostart = false
	add_child(_resize_timer)

	_connect_signals()
	_reset_output()
	_initialized = true


# Called from the template when the user copy paste nodes
func init_from_node(node: ConceptNode) -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()

	unique_id = node.unique_id
	display_name = node.display_name
	category = node.category
	description = node.description
	node_pool = node.node_pool
	thread_pool = node.thread_pool

	_inputs = node._inputs
	_outputs = node._outputs
	_hboxes = []

	for b in node._hboxes:
		var d = b.duplicate()
		add_child(d)
		_hboxes.append(d)

	_setup_slots()
	_generate_default_gui_style()
	_initialized = true


"""
Override and make it return true if your node should be instanced from a scene directly.
Scene should have the same name as the script and use a .tscn extension.
When using a custom gui, you lose access to the default gui. You have to define slots and undo
redo yourself but you have complete control over the node appearance and behavior.
"""
func has_custom_gui() -> bool:
	return false


func is_output_ready() -> bool:
	return _output_ready


"""
Call this first to generate everything in the background first. This method then emits a signal
when the results are ready. Outputs can then be fetched using the get_output method.
"""
func prepare_output() -> void:
	if not _initialized or not get_parent():
		return

	# If the output was already generated, skip the whole function and notify directly
	if is_output_ready():
		call_deferred("emit_signal", "output_ready")
		return

	if _generation_requested:	# Prepare output was already called
		return

	_generation_requested = true

	if not _request_inputs_to_get_ready():
		yield(self, "all_inputs_ready")

	call_deferred("_run_background_generation") # Single thread execution
	#thread_pool.submit_task(self, "_run_background_generation") # Broken multithread execution


"""
Returns the associated data to the given slot index. It either comes from a connected input node,
or from a local control field in the case of a simple type (float, string)
"""
func get_input(idx: int, default = []) -> Array:
	var parent = get_parent()
	if not parent:
		return default

	var input: Dictionary = parent.get_left_node(self, idx)
	if input.has("node"):	# Input source connected, ignore local data
		return input["node"].get_output(input["slot"], default)

	if has_custom_gui():
		var output = _get_input(idx)
		if output == null:
			return default
		return output

	# If no source is connected, check if it's a base type with a value defined on the node itself
	match _inputs[idx]["type"]:
		ConceptGraphDataType.BOOLEAN:
			return [_hboxes[idx].get_node("CheckBox").pressed]
		ConceptGraphDataType.SCALAR:
			return [_hboxes[idx].get_node("SpinBox").value]
		ConceptGraphDataType.STRING:
			if _hboxes[idx].has_node("LineEdit"):
				return [_hboxes[idx].get_node("LineEdit").text]
			elif _hboxes[idx].has_node("OptionButton"):
				var btn = _hboxes[idx].get_node("OptionButton")
				return [btn.get_item_text(btn.selected)]

	return default # Not a base type and no source connected


"""
By default, every input and output is an array. This is just a short hand with all the necessary
checks that returns the first value of the input.
"""
func get_input_single(idx: int, default = null):
	var input = get_input(idx)
	if input == null or input.size() == 0 or input[0] == null:
		return default
	return input[0]


"""
Returns what the node generates for a given slot
This method ensure the output is not calculated more than one time per run. It's useful if the
output node is connected to more than one node. It ensure the results are the same and save
some performance
"""
func get_output(idx: int, default := []) -> Array:
	if not is_output_ready():
		return default

	var res = output[idx]
	if not res is Array:
		res = [res]
	if res.size() == 0:
		return default

	# If the output is a node array, we need to duplicate them first otherwise they get passed as
	# references which causes issues when the same output is sent to two different nodes.
	if res[0] is Node:
		var duplicates = []
		for i in res.size():
			var node = res[i].duplicate(7)
			register_to_garbage_collection(node)
			duplicates.append(node)
		return duplicates

	# If it's not a node array, it's made of built in types (scalars, vectors ...) which are passed
	# as copy by default.
	return res


"""
Query the parent ConceptGraph node in the editor and returns the corresponding input node if it
exists
"""
func get_editor_input(name: String) -> Node:
	var parent = get_parent()
	if not parent:
		return null
	var input = parent.concept_graph.get_input(name)
	if not input:
		return null

	var input_copy = input.duplicate(7)
	register_to_garbage_collection(input_copy)
	return input_copy


"""
Return the variables exposed to the node inspector. Same format as get_property_list
[ {name: , type: }, ... ]
"""
func get_exposed_variables() -> Array:
	return []


func get_concept_graph():
	return get_parent().concept_graph


"""
Clears the cache and the cache of every single nodes right to this one.
"""
func reset() -> void:
	clear_cache()
	for node in get_parent().get_all_right_nodes(self):
		node.reset()


func clear_cache() -> void:
	_clear_cache()
	_reset_output()
	_output_ready = false


func export_editor_data() -> Dictionary:
	var editor_scale = ConceptGraphEditorUtil.get_dpi_scale()
	var data = {}
	data["offset_x"] = offset.x / editor_scale
	data["offset_y"] = offset.y / editor_scale

	if resizable:
		data["rect_x"] = rect_size.x
		data["rect_y"] = rect_size.y

	data["slots"] = {}
	var slots = _hboxes.size()
	for i in range(0, slots):
		var hbox = _hboxes[i]
		for c in hbox.get_children():
			if c is CheckBox:
				data["slots"][i] = c.pressed
			if c is SpinBox:
				data["slots"][i] = c.value
			if c is LineEdit:
				data["slots"][i] = c.text
			if c is OptionButton:
				data["slots"][i] = c.get_item_id(c.selected)

	return data


func restore_editor_data(data: Dictionary) -> void:
	var editor_scale = ConceptGraphEditorUtil.get_dpi_scale()
	offset.x = data["offset_x"] * editor_scale
	offset.y = data["offset_y"] * editor_scale

	if data.has("rect_x"):
		rect_size.x = data["rect_x"]
	if data.has("rect_y"):
		rect_size.y = data["rect_y"]
	emit_signal("resize_request", rect_size)

	if has_custom_gui():
		return

	var slots = _hboxes.size()
	for i in range(0, slots):
		if data["slots"].has(String(i)):
			var type = _inputs[i]["type"]
			var value = data["slots"][String(i)]
			var hbox = _hboxes[i]
			match type:
				ConceptGraphDataType.BOOLEAN:
					hbox.get_node("CheckBox").pressed = value
				ConceptGraphDataType.SCALAR:
					hbox.get_node("SpinBox").value = value
				ConceptGraphDataType.STRING:
					if hbox.has_node("LineEdit"):
						hbox.get_node("LineEdit").text = value
					elif hbox.has_node("OptionButton"):
						var btn: OptionButton = hbox.get_node("OptionButton")
						btn.selected = btn.get_item_index(value)


"""
Because we're saving the tree to a json file, we need each node to explicitely specify the data
to save. It's also the node responsability to restore it when we load the file. Most nodes
won't need this but it could be useful for nodes that allows the user to type in raw values
directly if nothing is connected to a slot.
"""
func export_custom_data() -> Dictionary:
	return {}


"""
This method get exactly what it exported from the export_custom_data method. Use it to manually
restore the previous node state.
"""
func restore_custom_data(data: Dictionary) -> void:
	pass


func is_input_connected(idx: int) -> bool:
	var parent = get_parent()
	if not parent:
		return false

	return parent.is_node_connected_to_input(self, idx)


func set_input(idx: int, name: String, type: int, opts: Dictionary = {}) -> void:
	_inputs[idx] = {
		"name": name,
		"type": type,
		"options": opts,
		"mirror": []
	}


func set_output(idx: int, name: String, type: int, opts: Dictionary = {}) -> void:
	_outputs[idx] = {
		"name": name,
		"type": type,
		"options": opts
	}


func remove_input(idx: int) -> bool:
	if not _inputs.has(idx):
		return false

	if is_input_connected(idx):
		get_parent()._disconnect_input(self, idx)

	_inputs.erase(idx)
	return true


func mirror_slots_type(input_index, output_index) -> void:
	if input_index >= _inputs.size():
		print("Error: invalid input index passed to mirror_slots_type ", input_index)
		return

	if output_index >= _outputs.size():
		print("Error: invalid output index passed to mirror_slots_type ", output_index)
		return

	_inputs[input_index]["mirror"].append(output_index)
	_inputs[input_index]["default_type"] = _inputs[input_index]["type"]


"""
Override the default gui value with a new one. // TODO : might not be useful, could be removed if not used
"""
func set_default_gui_input_value(idx: int, value) -> void:
	if _hboxes.size() <= idx:
		return

	var hbox = _hboxes[idx]
	var type = _inputs[idx]["type"]
	match type:
		ConceptGraphDataType.BOOLEAN:
			hbox.get_node("CheckBox").pressed = value
		ConceptGraphDataType.SCALAR:
			hbox.get_node("SpinBox").value = value
		ConceptGraphDataType.STRING:
			hbox.get_node("LineEdit").text = value


"""
Override this method when exposing a variable to the inspector. It's up to you to decide what to
do with the user defined value.
"""
func set_value_from_inspector(_name: String, _value) -> void:
	pass


func register_to_garbage_collection(resource):
	get_parent().register_to_garbage_collection(resource)


"""
Some UI elements are broken the first time the graph is generated. Not sure if it's because it's
a child of a spatial node or something else. This is called when the template is disconnected
from the ConceptGraph and parented to the graph editor. Regenerating problematic parts of the UI
works at that moment.
"""
func post_generation_ui_fixes():
	# Regenerate the font style to avoid using the default one
	_generate_default_gui_style()

	# OptionButtons doesn't work so we recreate them here, reconnect the signals and fire them once
	for box in _hboxes:
		for ui in box.get_children():
			if ui is OptionButton:
				var new_btn: OptionButton = ui.duplicate()
				var pos = ui.get_position_in_parent()
				box.remove_child(ui)
				if pos - 1 < 0:
					box.add_child_below_node(box, new_btn)
				else:
					box.add_child_below_node(box.get_child(pos - 1), new_btn)

				var slot = box.get_position_in_parent()
				new_btn.connect("item_selected", self, "_on_default_gui_value_changed", [slot])
				new_btn.connect("item_selected", self, "_on_default_gui_interaction", [new_btn, slot])
				_on_default_gui_interaction(new_btn.get_item_text(new_btn.get_item_id(new_btn.selected)), new_btn, slot)
				ui.queue_free()


"""
Returns a list of every ConceptNode connected to this node
"""
func _get_connected_inputs() -> Array:
	var connected_inputs = []
	for i in _inputs.size():
		var info = get_parent().get_left_node(self, i)
		if info.has("node"):
			connected_inputs.append(info["node"])
	return connected_inputs


"""
Loops through all connected input nodes and request them to prepare their output. Each output
then signals this node when they finished their task. When all the inputs are ready, signals this
node that the generation can begin.
Returns true if all inputs are already ready.
"""
func _request_inputs_to_get_ready() -> bool:
	var connected_inputs = _get_connected_inputs()

	# No connected nodes, inputs data are available locally
	if connected_inputs.size() == 0:
		return true

	# Call prepare_output on every connected inputs
	for input_node in connected_inputs:
		if not input_node.is_connected("output_ready", self, "_on_input_ready"):
			input_node.connect("output_ready", self, "_on_input_ready")
		input_node.call_deferred("prepare_output")
	return false


"""
This function is ran in the background from prepare_output(). Emits a signal when the outputs
are ready.
"""
func _run_background_generation() -> void:
	_generate_outputs()
	_output_ready = true
	_generation_requested = false
	call_deferred("emit_signal", "output_ready")


"""
Overide this function in the derived classes to return something usable.
Generate all the outputs for every output slots declared.
"""
func _generate_outputs() -> void:
	pass


"""
Override this if you're using a custom GUI to change input slots default behavior. This returns
the local input data for the given slot
"""
func _get_input(index: int) -> Array:
	return []


"""
Overide this function to customize how the output cache should be cleared. If you have memory
to free or anything else, that's where you should define it.
"""
func _clear_cache():
	pass


"""
Clear previous outputs and create as many empty arrays as there are output slots in the graph node.
"""
func _reset_output():
	for slot in output:
		if slot is Array:
			for res in slot:
				if res is Node:
					res.queue_free()
		elif slot is Node:
			slot.queue_free()

	output = []
	for i in _outputs.size():
		output.append([])


"""
Based on the previous calls to set_input and set_ouput, this method will call the
GraphNode.set_slot method accordingly with the proper parameters. This makes it easier syntax
wise on the child node side and make it more readable.
"""
func _setup_slots() -> void:
	var slots = _hboxes.size()
	for i in slots:
		var has_input = false
		var input_type = 0
		var input_color = Color(0)
		var has_output = false
		var output_type = 0
		var output_color = Color(0)

		if _inputs.has(i):
			has_input = true
			input_type = _inputs[i]["type"]
			input_color = ConceptGraphDataType.COLORS[input_type]
		if _outputs.has(i):
			has_output = true
			output_type = _outputs[i]["type"]
			output_color = ConceptGraphDataType.COLORS[output_type]

		if not has_input and not has_output:
			_hboxes[i].visible = false

		# This causes more issues than it solves
		#if _inputs[i].has("options") and _inputs[i]["options"].has("disable_slot"):
		#	has_input = not _inputs[i]["options"]["disable_slot"]

		set_slot(i, has_input, input_type, input_color, has_output, output_type, output_color)

	for b in _hboxes:
		if not b.visible:
			_hboxes.erase(b)
			remove_child(b)
	if not resizable:
		emit_signal("resize_request", Vector2.ZERO)


"""
Based on graph node category this method will setup corresponding style and color of graph node
"""
func _generate_default_gui_style() -> void:
	# Base Style
	var style = StyleBoxFlat.new()
	var color = Color(0.121569, 0.145098, 0.192157, 0.9)
	style.border_color = ConceptGraphDataType.to_category_color(category)
	style.set_bg_color(color)
	style.set_border_width_all(2)
	style.set_border_width(MARGIN_TOP, 32)
	style.content_margin_left = 24;
	style.content_margin_right = 24;
	style.set_corner_radius_all(4)
	style.set_expand_margin_all(4)
	style.shadow_size = 8
	style.shadow_color = Color(0,0,0,0.2)
	add_stylebox_override("frame", style)

	# Selected Style
	var selected_style = style.duplicate()
	selected_style.shadow_color = ConceptGraphDataType.to_category_color(category)
	selected_style.shadow_size = 4
	selected_style.border_color = Color(0.121569, 0.145098, 0.192157, 0.9)
	add_stylebox_override("selectedframe", selected_style)
	add_constant_override("port_offset", 12)
	add_font_override("title_font", get_font("bold", "EditorFonts"))


"""
If the child node does not define a custom UI itself, this function will generate a default UI
based on the parameters provided with set_input and set_ouput. Each slots will have a Label
and their name attached.
The input slots will have additional UI elements based on their type.
Scalars input gets a spinbox that's hidden when something is connected to the slot.
Values stored in the spinboxes are automatically exported and restored.
"""
func _generate_default_gui() -> void:
	if has_custom_gui():
		return

	for box in _hboxes:
		remove_child(box)
		box.queue_free()
	_hboxes = []

	_generate_default_gui_style()

	title = display_name
	resizable = false
	show_close = true
	rect_min_size = Vector2(0.0, 0.0)
	rect_size = Vector2(0.0, 0.0)

	# TODO : Some refactoring would be nice
	var slots = max(_inputs.size(), _outputs.size())
	for i in range(0, slots):

		# Create a Hbox container per slot like this -> [LabelIn, (opt), LabelOut]
		var hbox = HBoxContainer.new()
		hbox.rect_min_size.y = 24

		# Hbox have at least two elements (In and Out label), or more for some base types
		# for example with additional spinboxes. All of them are stored in ui_elements
		var ui_elements = []

		# label_left holds the name of the input slot.
		var label_left = Label.new()
		label_left.name = "LabelLeft"
		label_left.mouse_filter = MOUSE_FILTER_PASS
		ui_elements.append(label_left)

		# If this slot has an input
		if _inputs.has(i):
			label_left.text = _inputs[i]["name"]
			label_left.hint_tooltip = ConceptGraphDataType.Types.keys()[_inputs[i]["type"]].capitalize()

			# Add the optional UI elements based on the data type.
			# TODO : We could probably just check if the property exists with get_property_list
			# and to that automatically instead of manually setting everything one by one
			match _inputs[i]["type"]:
				ConceptGraphDataType.BOOLEAN:
					var opts = _inputs[i]["options"]
					var checkbox = CheckBox.new()
					checkbox.name = "CheckBox"
					checkbox.pressed = opts["value"] if opts.has("value") else false
					checkbox.connect("toggled", self, "_on_default_gui_value_changed", [i])
					checkbox.connect("toggled", self, "_on_default_gui_interaction", [checkbox, i])
					ui_elements.append(checkbox)
				ConceptGraphDataType.SCALAR:
					var opts = _inputs[i]["options"]
					var spinbox = SpinBox.new()
					spinbox.name = "SpinBox"
					spinbox.max_value = opts["max"] if opts.has("max") else 1000
					spinbox.min_value = opts["min"] if opts.has("min") else 0
					spinbox.value = opts["value"] if opts.has("value") else 0
					spinbox.step = opts["step"] if opts.has("step") else 0.001
					spinbox.exp_edit = opts["exp"] if opts.has("exp") else true
					spinbox.allow_greater = opts["allow_greater"] if opts.has("allow_greater") else true
					spinbox.allow_lesser = opts["allow_lesser"] if opts.has("allow_lesser") else false
					spinbox.rounded = opts["rounded"] if opts.has("rounded") else false
					spinbox.connect("value_changed", self, "_on_default_gui_value_changed", [i])
					spinbox.connect("value_changed", self, "_on_default_gui_interaction", [spinbox, i])
					ui_elements.append(spinbox)
				ConceptGraphDataType.STRING:
					var opts = _inputs[i]["options"]
					if opts.has("type") and opts["type"] == "dropdown":
						var dropdown = OptionButton.new()
						dropdown.name = "OptionButton"
						for item in opts["items"].keys():
							dropdown.add_item(item, opts["items"][item])
						dropdown.connect("item_selected", self, "_on_default_gui_value_changed", [i])
						dropdown.connect("item_selected", self, "_on_default_gui_interaction", [dropdown, i])
						ui_elements.append(dropdown)
					else:
						var line_edit = LineEdit.new()
						line_edit.name = "LineEdit"
						line_edit.placeholder_text = opts["placeholder"] if opts.has("placeholder") else "Text"
						line_edit.expand_to_text_length = opts["expand"] if opts.has("expand") else true
						line_edit.connect("text_changed", self, "_on_default_gui_value_changed", [i])
						line_edit.connect("text_changed", self, "_on_default_gui_interaction", [line_edit, i])
						ui_elements.append(line_edit)

		# Label right holds the output slot name. Set to expand and align_right to push the text on
		# the right side of the node panel
		var label_right = Label.new()
		label_right.name = "LabelRight"
		label_right.mouse_filter = MOUSE_FILTER_PASS
		label_right.size_flags_horizontal = SIZE_EXPAND_FILL
		label_right.align = Label.ALIGN_RIGHT

		if _outputs.has(i):
			label_right.text = _outputs[i]["name"]
			label_right.hint_tooltip = ConceptGraphDataType.Types.keys()[_outputs[i]["type"]].capitalize()
		ui_elements.append(label_right)

		# Make sure it appears in the editor and store along the other Hboxes
		_hboxes.append(hbox)
		add_child(hbox)

		# Push all the ui elements in order in the Hbox container
		for ui in ui_elements:
			hbox.add_child(ui)

	hide()
	show()


func _connect_signals() -> void:
	connect("close_request", self, "_on_close_request")
	connect("resize_request", self, "_on_resize_request")
	connect("connection_changed", self, "_on_connection_changed")
	_resize_timer.connect("timeout", self, "_on_resize_timeout")


"""
Called when a connected input node has finished generating its output data. This method checks
if every other connected node has completed their task. If they are ready, notify this node to
resume its output generation
"""
func _on_input_ready() -> void:
	#print("Input ready received on ", display_name)
	var all_inputs_ready := true
	var connected_inputs := _get_connected_inputs()
	for input_node in connected_inputs:
		if not input_node.is_output_ready():
			all_inputs_ready = false

	if all_inputs_ready:
		emit_signal("all_inputs_ready")


func _on_resize_request(new_size) -> void:
	rect_size = new_size
	_resize_timer.start(2.0)


func _on_resize_timeout() -> void:
	emit_signal("node_changed", self, false)


func _on_close_request() -> void:
	emit_signal("delete_node", self)


"""
When the nodes connections changes, this method checks for all the input slots and hides
everything that's not a label if something is connected to the associated slot.
"""
func _on_connection_changed() -> void:
	var slots_types_updated = false
	for i in _hboxes.size():
		var input_connected = is_input_connected(i)
		for ui in _hboxes[i].get_children():
			if not ui is Label:
				ui.visible = !input_connected

		# Handle dynamic slot type
		if i >= _inputs.size():
			continue
		for o in _inputs[i]["mirror"]:
			slots_types_updated = true
			var type = _inputs[i]["default_type"]
			# Copy the connected input type if there's one
			if input_connected:
				var data = get_parent().get_left_node(self, i)
				type = data["node"]._outputs[data["slot"]]["type"]

			_inputs[i]["type"] = type
			_outputs[o]["type"] = type

	if slots_types_updated:
		_generate_default_gui()
		_setup_slots()

	hide()
	show()


func _on_default_gui_value_changed(value, slot: int) -> void:
	emit_signal("node_changed", self, true)
	emit_signal("input_changed", slot, value)
	reset()


func _on_default_gui_interaction(value, control, slot) -> void:
	pass
