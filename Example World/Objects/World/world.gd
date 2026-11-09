extends Node3D

const PLAYER_SCENE: PackedScene = preload("res://Player_Controller/player_character.tscn")
const LOBBY_NAME := "FPS_LOBBY"

# Titik spawn dasar. Sama di semua client supaya node sejajar.
const SPAWN_BASE := Vector3(14.9, 2.4, 6.1)

# Node player MILIK client ini (dipakai untuk memberitahu client lain agar
# menghapusnya saat kita menutup game).
var _local_player: Node = null

#region Live Chat UI & State
var _chat_layer: CanvasLayer
var _chat_log: RichTextLabel
var _chat_input: LineEdit
var _is_chat_open: bool = false
#endregion

@onready var players_container: Node3D = $PlayersContainer

func _ready() -> void:
	GDSync.connected.connect(_on_connected)
	GDSync.connection_failed.connect(_on_connection_failed)
	GDSync.disconnected.connect(_on_disconnected)
	GDSync.lobby_created.connect(_on_lobby_created)
	GDSync.lobby_creation_failed.connect(_on_lobby_creation_failed)
	GDSync.lobby_joined.connect(_on_lobby_joined)
	GDSync.lobby_join_failed.connect(_on_lobby_join_failed)
	# Saat pemain lain keluar/menutup game, hapus node player mereka.
	GDSync.client_left.connect(_on_client_left)
	# Izinkan client lain memanggil fungsi visual peluru ini.
	GDSync.expose_func(spawn_projectile_visual)
	# Izinkan client lain mengirim pesan live chat ke semua orang.
	GDSync.expose_func(receive_chat_message)
	_setup_chat_ui()
	# Kadang client menerima node player yang sama dua kali saat join (race di
	# dalam plugin). Kita bereskan duplikatnya tiap ada player baru masuk.
	players_container.child_entered_tree.connect(_on_player_entered)
	# Tangani tombol close OS sendiri, supaya kita bisa keluar lobby dengan rapi
	# (lihat _notification) sehingga pemain lain langsung melihat kita menghilang.
	get_tree().auto_accept_quit = false
	# Mulai multiplayer ONLINE lewat server GD-Sync (butuh API key di keys.cfg).
	# Pemain cukup membuka game: otomatis bergabung ke lobby (lihat _on_connected).
	GDSync.start_multiplayer()

func _notification(what: int) -> void:
	# Pemain menutup jendela game: keluar dari lobby dengan rapi.
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_quit_gracefully.call_deferred()

func _quit_gracefully() -> void:
	# Cara resmi GD-Sync untuk menghapus node di SEMUA client: berbasis path node,
	# jadi tidak bergantung pada data owner (yang ternyata tidak selalu tersinkron
	# ke client lain). Setiap client lain akan menjalankan queue_free pada node ini.
	if GDSync.is_active() and is_instance_valid(_local_player):
		GDSync.multiplayer_queue_free(_local_player)
	# Beri waktu request terkirim, baru keluar lobby dan tutup game.
	await get_tree().create_timer(0.4).timeout
	if GDSync.is_active():
		GDSync.lobby_leave()
	await get_tree().create_timer(0.15).timeout
	get_tree().quit()

func _on_player_entered(_node: Node) -> void:
	_dedupe_players.call_deferred()

# Hapus node player duplikat (yang punya meta "GDID" sama). Node duplikat ini
# datang dari replikasi plugin, jadi cukup di-free lokal (jangan lewat jaringan).
func _dedupe_players() -> void:
	var seen: Dictionary = {}
	for child in players_container.get_children():
		var gdid = child.get_meta("GDID", null)
		if gdid == null:
			continue
		if seen.has(gdid):
			child.queue_free()
		else:
			seen[gdid] = child

func _on_connected() -> void:
	print("Terhubung ke GD-Sync. Client ID: ", GDSync.get_client_id())
	# AUTO JOIN: coba gabung ke lobby dulu. Kalau lobby belum ada, kita buat
	# (lihat _on_lobby_join_failed). Jadi pemain tinggal buka game langsung masuk.
	GDSync.lobby_join(LOBBY_NAME)

func _on_connection_failed(error: int) -> void:
	push_error("Gagal terhubung ke GD-Sync (error %d). Periksa API key dan koneksi internet." % error)

func _on_disconnected() -> void:
	print("Terputus dari GD-Sync.")

func _on_lobby_created(lobby_name: String) -> void:
	print("Lobby dibuat: ", lobby_name)
	# Pembuat lobby HARUS bergabung juga. lobby_create tidak otomatis join,
	# kalau tidak di-join maka host tidak berada di dalam lobby.
	GDSync.lobby_join(lobby_name)

func _on_lobby_creation_failed(lobby_name: String, error: int) -> void:
	# Lobby dengan nama yang sama sudah ada (mis. sisa sesi sebelumnya).
	# Daripada gagal, langsung bergabung saja.
	if error == ENUMS.LOBBY_CREATION_ERROR.LOBBY_ALREADY_EXISTS:
		print("Lobby sudah ada, bergabung: ", lobby_name)
		GDSync.lobby_join(lobby_name)
	else:
		push_error("Gagal membuat lobby %s (error %d)." % [lobby_name, error])

func _on_lobby_joined(lobby_name: String) -> void:
	print("Bergabung ke lobby: ", lobby_name)
	spawn_local_player()

func _on_lobby_join_failed(lobby_name: String, error: int) -> void:
	# AUTO JOIN: kalau lobby belum ada, kita yang membuatnya (lalu otomatis join
	# lewat _on_lobby_created). Dengan begitu pemain cukup membuka game.
	if error == ENUMS.LOBBY_JOIN_ERROR.LOBBY_DOES_NOT_EXIST:
		print("Lobby belum ada, membuat: ", lobby_name)
		GDSync.lobby_create(lobby_name)
	else:
		push_error("Gagal bergabung ke lobby %s (error %d)." % [lobby_name, error])

## Dipanggil saat client lain keluar/menutup game. GD-Sync TIDAK otomatis menghapus
## node player mereka (SessionController.client_left hanya membersihkan data),
## jadi tiap client menghapus salinan node pemain yang keluar di sini.
func _on_client_left(client_id: int) -> void:
	print("Pemain keluar: ", client_id)
	for child in players_container.get_children():
		if GDSync.get_gdsync_owner(child) == client_id:
			child.queue_free()

# Hanya membuat player MILIK client ini. GD-Sync menyalinnya ke semua client lain
# dan ke client yang bergabung belakangan (replicate_on_join = true).
func spawn_local_player() -> void:
	var client_id: int = GDSync.get_client_id()

	var player: Node3D = GDSync.multiplayer_instantiate(PLAYER_SCENE, players_container)
	if player == null:
		push_error("Gagal membuat player untuk client %d." % client_id)
		return
	_local_player = player
	# JANGAN mengubah player.name: nama node harus sama di semua client supaya
	# path node cocok dan sinkronisasi posisi/ownership berjalan.
	player.global_position = _spawn_position(client_id)
	# Owner = client pemilik player ini. Script player memakai ini untuk tahu
	# instance mana yang dikendalikan secara lokal (dan mana yang cuma tampil).
	GDSync.set_gdsync_owner(player, client_id)

func _spawn_position(client_id: int) -> Vector3:
	# Posisi spawn deterministik berdasarkan client id, supaya tiap pemain dapat
	# titik berbeda (tidak menumpuk di lokasi yang sama).
	var angle: float = float(client_id % 8) * TAU / 8.0
	return SPAWN_BASE + Vector3(cos(angle) * 3.0, 0.0, sin(angle) * 3.0)

## Dipanggil lewat jaringan oleh penembak untuk menampilkan peluru di client lain.
## Ini HANYA visual (tidak menghitung damage) supaya tiap peluru hanya melukai
## sekali, yaitu di client penembak.
func spawn_projectile_visual(scene_path: String, origin: Vector3, velocity: Vector3, lifetime: float) -> void:
	var scene: PackedScene = load(scene_path)
	if scene == null:
		return
	var projectile: Node3D = scene.instantiate()
	add_child(projectile)
	projectile.global_position = origin
	var speed: float = velocity.length()
	if speed > 0.01 and abs(velocity.normalized().dot(Vector3.UP)) < 0.99:
		projectile.look_at(origin + velocity.normalized())
	if projectile is RigidBody3D:
		projectile.set_linear_velocity(velocity)
	get_tree().create_timer(lifetime).timeout.connect(func() -> void:
		if is_instance_valid(projectile):
			projectile.queue_free())

#region Live Chat Implementation
func _setup_chat_ui() -> void:
	_chat_layer = CanvasLayer.new()
	_chat_layer.layer = 10
	add_child(_chat_layer)

	var panel := PanelContainer.new()
	panel.position = Vector2(20, 420)
	panel.size = Vector2(380, 200)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.45)
	style.set_corner_radius_all(6)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", style)
	_chat_layer.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	# Area live chat semua orang di bagian atas
	_chat_log = RichTextLabel.new()
	_chat_log.bbcode_enabled = true
	_chat_log.scroll_following = true
	_chat_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_chat_log.selection_enabled = false
	_chat_log.append_text("[color=#aaaaaa]Tekan '/' untuk mengetik chat...[/color]\n")
	vbox.add_child(_chat_log)

	# Form input ketik chat di bagian bawah
	_chat_input = LineEdit.new()
	_chat_input.placeholder_text = "Ketik pesan lalu tekan Enter..."
	_chat_input.visible = false
	_chat_input.text_submitted.connect(_on_chat_submitted)
	vbox.add_child(_chat_input)

func _input(event: InputEvent) -> void:
	if not _is_chat_open:
		if event.is_action_pressed("chat"):
			get_viewport().set_input_as_handled()
			_open_chat()
	else:
		if event.is_action_pressed("ui_cancel"):
			get_viewport().set_input_as_handled()
			_close_chat()

func _open_chat() -> void:
	_is_chat_open = true
	_chat_input.visible = true
	_chat_input.text = ""
	_chat_input.grab_focus()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	if is_instance_valid(_local_player) and _local_player.has_method("set_chat_active"):
		_local_player.set_chat_active(true)

func _close_chat() -> void:
	_is_chat_open = false
	_chat_input.release_focus()
	_chat_input.text = ""
	_chat_input.visible = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	if is_instance_valid(_local_player) and _local_player.has_method("set_chat_active"):
		_local_player.set_chat_active(false)

func _on_chat_submitted(new_text: String) -> void:
	var msg: String = new_text.strip_edges()
	if msg != "":
		var sender: String = "Player %d" % GDSync.get_client_id()
		if GDSync.is_active():
			GDSync.call_func_all(receive_chat_message, sender, msg)
		else:
			receive_chat_message(sender, msg)
	_close_chat()

func receive_chat_message(sender: String, message: String) -> void:
	if _chat_log:
		_chat_log.append_text("[b][color=#55ccff]%s:[/color][/b] %s\n" % [sender, message])
#endregion
