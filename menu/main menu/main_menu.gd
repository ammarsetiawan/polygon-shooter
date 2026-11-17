extends Control
class_name MainMenu

const WORLD_SCENE_PATH := "res://Example World/Objects/World/world.tscn"

@onready var play_button: Button = %PlayButton
@onready var settings_button: Button = %SettingsButton
@onready var controls_button: Button = %ControlsButton
@onready var quit_button: Button = %QuitButton

@onready var settings_panel: PanelContainer = %SettingsPanel
@onready var controls_panel: PanelContainer = %ControlsPanel

@onready var volume_slider: HSlider = %VolumeSlider
@onready var volume_value_label: Label = %VolumeValueLabel
@onready var fullscreen_check: CheckButton = %FullscreenCheck
@onready var close_settings_button: Button = %CloseSettingsButton
@onready var close_controls_button: Button = %CloseControlsButton
@onready var status_label: Label = %StatusLabel

# Kolom nama pemain, dibuat lewat kode (lihat _setup_name_input).
var name_input: LineEdit

func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	
	play_button.pressed.connect(_on_play_pressed)
	settings_button.pressed.connect(_on_settings_pressed)
	controls_button.pressed.connect(_on_controls_pressed)
	quit_button.pressed.connect(_on_quit_pressed)
	
	close_settings_button.pressed.connect(func() -> void: settings_panel.visible = false)
	close_controls_button.pressed.connect(func() -> void: controls_panel.visible = false)
	
	volume_slider.value_changed.connect(_on_volume_changed)
	fullscreen_check.toggled.connect(_on_fullscreen_toggled)
	
	# Kolom isian nama pemain di atas tombol menu.
	_setup_name_input()
	
	# Inisialisasi nilai pengaturan saat ini
	var current_db: float = AudioServer.get_bus_volume_db(0)
	volume_slider.value = clampf(db_to_linear(current_db) * 100.0, 0.0, 100.0)
	_update_volume_label(volume_slider.value)
	fullscreen_check.button_pressed = DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN

## Membuat kolom "NAMA PEMAIN" secara kode (tanpa mengubah file scene).
func _setup_name_input() -> void:
	var buttons_vbox: VBoxContainer = play_button.get_parent() as VBoxContainer
	if buttons_vbox == null:
		return
	
	var box := VBoxContainer.new()
	box.name = "NameBox"
	box.add_theme_constant_override("separation", 6)
	
	var label := Label.new()
	label.name = "NameLabel"
	label.text = "NAMA PEMAIN"
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", Color(0.35, 0.8, 1, 1))
	box.add_child(label)
	
	name_input = LineEdit.new()
	name_input.name = "NameInput"
	name_input.placeholder_text = "Ketik nama kamu..."
	name_input.max_length = PlayerProfile.MAX_NAME_LENGTH
	name_input.custom_minimum_size = Vector2(0, 40)
	name_input.text_submitted.connect(func(_text: String) -> void: _on_play_pressed())
	# Isi otomatis dari nama yang tersimpan sebelumnya, kalau ada.
	name_input.text = PlayerProfile.load_name()
	box.add_child(name_input)
	
	buttons_vbox.add_child(box)
	buttons_vbox.move_child(box, 0)
	name_input.grab_focus()

func _on_play_pressed() -> void:
	# Wajib mengisi nama sebelum bisa bermain.
	var chosen: String = ""
	if name_input:
		chosen = PlayerProfile.sanitize(name_input.text)
	if chosen == "":
		status_label.text = "Isi nama kamu dulu untuk bermain."
		if name_input:
			name_input.grab_focus()
		return
	
	PlayerProfile.save_name(chosen)
	play_button.disabled = true
	status_label.text = "Memuat arena multiplayer sebagai %s..." % chosen
	get_tree().change_scene_to_file(WORLD_SCENE_PATH)

func _on_settings_pressed() -> void:
	controls_panel.visible = false
	settings_panel.visible = not settings_panel.visible

func _on_controls_pressed() -> void:
	settings_panel.visible = false
	controls_panel.visible = not controls_panel.visible

func _on_quit_pressed() -> void:
	get_tree().quit()

func _on_volume_changed(value: float) -> void:
	_update_volume_label(value)
	if value <= 0.01:
		AudioServer.set_bus_mute(0, true)
	else:
		AudioServer.set_bus_mute(0, false)
		AudioServer.set_bus_volume_db(0, linear_to_db(value / 100.0))

func _update_volume_label(value: float) -> void:
	if volume_value_label:
		volume_value_label.text = "%d%%" % roundi(value)

func _on_fullscreen_toggled(toggled_on: bool) -> void:
	if toggled_on:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
