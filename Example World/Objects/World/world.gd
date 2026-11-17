extends Node3D

const PLAYER_SCENE: PackedScene = preload("res://Player_Controller/player_character.tscn")
const ARENA_BUILDER: GDScript = preload("res://Example World/Objects/World/arena_builder.gd")
const LOBBY_NAME := "POLYGON_FPS_ARENA"

# Titik spawn dasar. Sama di semua client supaya node sejajar.
const SPAWN_BASE := Vector3(14.9, 2.4, 6.1)

# Node player MILIK client ini (dipakai untuk memberitahu client lain agar
# menghapusnya saat kita menutup game).
var _local_player: Node = null

# Nama pemain ini (diisi di Main Menu, tersimpan lokal). Dipakai untuk username
# GD-Sync, chat, dan label di atas kepala pemain lain.
var _player_name: String = ""

# Timer sapuan berkala untuk membersihkan node pemain yang sudah keluar
# (lihat _sweep_departed_players).
var _sweep_timer: Timer

#region Lobby join/create retry state
# GD-Sync membatasi frekuensi pembuatan lobby (error ON_COOLDOWN) dan kadang
# sebuah join/create balapan (join bilang "tidak ada" padahal create bilang
# "sudah ada"). Kita ulangi dengan jeda supaya tidak mentok lalu player tidak
# pernah ter-spawn (gejala: layar abu-abu karena tidak ada kamera).
const LOBBY_JOIN_RETRY_DELAY := 0.8
const LOBBY_CREATE_RETRY_DELAY := 2.0
const MAX_LOBBY_ATTEMPTS := 8
var _lobby_attempts: int = 0
# Lobby utama bisa "nyangkut" (ghost lobby) akibat sesi sebelumnya yang ditutup
# paksa: create bilang sudah ada, tapi join bilang tidak ada. Kalau begitu kita
# bikin lobby cadangan bernama unik supaya pemain tetap bisa masuk & bermain.
var _using_fallback_lobby: bool = false
var _current_lobby_name: String = LOBBY_NAME
#endregion

#region Live Chat UI & State
# Ukuran panel chat + jarak dari tepi layar (panel ditempel di KANAN ATAS).
const CHAT_PANEL_SIZE := Vector2(380, 200)
const CHAT_MARGIN := 16.0
var _chat_layer: CanvasLayer
var _chat_log: RichTextLabel
var _chat_input: LineEdit
var _is_chat_open: bool = false
#endregion

@onready var players_container: Node3D = $PlayersContainer

func _ready() -> void:
	# Bangun arena baru dari kode & matikan geometri lama yang tersimpan di scene.
	_build_arena()
	# Ambil nama pemain yang diisi di Main Menu.
	_player_name = PlayerProfile.load_name()
	GDSync.connected.connect(_on_connected)
	GDSync.connection_failed.connect(_on_connection_failed)
	GDSync.disconnected.connect(_on_disconnected)
	GDSync.lobby_created.connect(_on_lobby_created)
	GDSync.lobby_creation_failed.connect(_on_lobby_creation_failed)
	GDSync.lobby_joined.connect(_on_lobby_joined)
	GDSync.lobby_join_failed.connect(_on_lobby_join_failed)
	# Saat pemain bergabung atau keluar/menutup game, tampilkan notif & bersihkan node.
	GDSync.client_joined.connect(_on_client_joined)
	GDSync.client_left.connect(_on_client_left)
	# Izinkan client lain memanggil fungsi visual peluru ini.
	GDSync.expose_func(spawn_projectile_visual)
	# Izinkan client lain mengirim pesan live chat ke semua orang.
	GDSync.expose_func(receive_chat_message)
	_setup_chat_ui()
	# Kadang client menerima node player yang sama dua kali saat join (race di
	# dalam plugin). Kita bereskan duplikatnya tiap ada player baru masuk.
	players_container.child_entered_tree.connect(_on_player_entered)
	# Sapuan berkala: hapus node pemain yang client-nya sudah keluar, supaya
	# pemain cepat hilang walau sinyal client_left telat (1 detik sekali).
	_sweep_timer = Timer.new()
	_sweep_timer.name = "PlayerSweepTimer"
	_sweep_timer.wait_time = 1.0
	_sweep_timer.autostart = true
	_sweep_timer.timeout.connect(_sweep_departed_players)
	add_child(_sweep_timer)
	# Tangani tombol close OS sendiri, supaya kita bisa keluar lobby dengan rapi
	# (lihat _notification) sehingga pemain lain langsung melihat kita menghilang.
	get_tree().auto_accept_quit = false
	# Mulai multiplayer ONLINE lewat server GD-Sync (butuh API key di keys.cfg).
	# Pemain cukup membuka game: otomatis bergabung ke lobby (lihat _on_connected).
	GDSync.start_multiplayer()

## Bangun arena baru dari kode (lihat arena_builder.gd), lalu matikan geometri
## CSG lama yang tersimpan di scene supaya keduanya tidak tumpang tindih.
## Geometri lama hanya disembunyikan (tidak dihapus) dan collision-nya dimatikan.
func _build_arena() -> void:
	for path in ["LevelGeometry", "ShadowLevelGeometry"]:
		var old: Node = get_node_or_null(path)
		if old == null:
			continue
		var old_3d := old as Node3D
		if old_3d:
			old_3d.visible = false
		var old_csg := old as CSGShape3D
		if old_csg:
			old_csg.use_collision = false
	var arena: Node3D = ARENA_BUILDER.new()
	arena.name = "Arena"
	add_child(arena)

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
	# Pastikan kita punya nama; kalau kosong (mis. menjalankan world langsung),
	# buat nama default berdasarkan client id.
	if _player_name == "":
		_player_name = "Player %d" % GDSync.get_client_id()
	# Set username GD-Sync supaya nama ini tersinkron ke semua pemain
	# (dipakai untuk chat dan label di atas kepala).
	GDSync.player_set_username(_player_name)
	print("Terhubung ke GD-Sync. Client ID: ", GDSync.get_client_id(), " | Nama: ", _player_name)
	# AUTO JOIN: coba gabung ke lobby dulu. Kalau lobby belum ada, kita buat
	# (lihat _on_lobby_join_failed). Jadi pemain tinggal buka game langsung masuk.
	_lobby_attempts = 0
	_attempt_join()

func _attempt_join() -> void:
	_lobby_attempts += 1
	if _lobby_attempts > MAX_LOBBY_ATTEMPTS:
		_fallback_lobby()
		return
	print("Mencoba bergabung ke lobby: ", _current_lobby_name)
	GDSync.lobby_join(_current_lobby_name)

func _attempt_create() -> void:
	_lobby_attempts += 1
	if _lobby_attempts > MAX_LOBBY_ATTEMPTS:
		_fallback_lobby()
		return
	print("Membuat lobby: ", _current_lobby_name)
	GDSync.lobby_create(_current_lobby_name)

## Dipanggil kalau lobby utama sudah tidak bisa dipakai lagi. Bikin nama lobby
## baru yang unik supaya kita dapat lobby segar (harus join pertama kali).
func _fallback_lobby() -> void:
	if _using_fallback_lobby:
		push_error("Gagal bergabung/membuat lobby meski sudah memakai nama cadangan. Periksa koneksi/API key GD-Sync.")
		return
	_using_fallback_lobby = true
	_current_lobby_name = "%s_%d" % [LOBBY_NAME, randi() % 100000]
	print("Lobby utama tidak bisa dipakai. Memakai lobby cadangan: ", _current_lobby_name)
	_lobby_attempts = 0
	_attempt_create()

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
	if error == ENUMS.LOBBY_CREATION_ERROR.LOBBY_ALREADY_EXISTS:
		# Lobby sudah ada (mis. sisa sesi / pemain lain). Jeda dulu supaya tidak
		# langsung berbenturan, lalu coba bergabung.
		print("Lobby sudah ada, mencoba bergabung: ", lobby_name)
		await get_tree().create_timer(LOBBY_JOIN_RETRY_DELAY).timeout
		_attempt_join()
	elif error == ENUMS.LOBBY_CREATION_ERROR.ON_COOLDOWN:
		# Server sedang membatasi pembuatan lobby; tunggu agak lama lalu ulangi.
		print("Pembuatan lobby sedang cooldown, menunggu lalu mengulang...")
		await get_tree().create_timer(LOBBY_CREATE_RETRY_DELAY).timeout
		_attempt_create()
	else:
		push_error("Gagal membuat lobby %s (error %d)." % [lobby_name, error])

func _on_lobby_joined(lobby_name: String) -> void:
	print("Bergabung ke lobby: ", lobby_name)
	spawn_local_player()

func _on_lobby_join_failed(lobby_name: String, error: int) -> void:
	# AUTO JOIN: kalau lobby belum ada, kita yang membuatnya (lalu otomatis join
	# lewat _on_lobby_created). Dengan begitu pemain cukup membuka game.
	if error == ENUMS.LOBBY_JOIN_ERROR.LOBBY_DOES_NOT_EXIST:
		print("Lobby belum ada, menunggu lalu membuat: ", lobby_name)
		_await_create()
	else:
		push_error("Gagal bergabung ke lobby %s (error %d)." % [lobby_name, error])

func _await_create() -> void:
	# Jeda sebelum membuat lobby untuk menghindari error ON_COOLDOWN dari server.
	await get_tree().create_timer(LOBBY_JOIN_RETRY_DELAY).timeout
	_attempt_create()

## Dipanggil saat pemain (kita atau pemain lain) bergabung ke dalam lobby.
func _on_client_joined(client_id: int) -> void:
	print("Pemain bergabung: ", client_id)
	if _chat_log:
		_chat_log.append_text("[color=#66ff88][i]* %s bergabung ke dalam game *[/i][/color]\n" % _display_name(client_id))

## Dipanggil saat client lain keluar/menutup game. GD-Sync TIDAK otomatis menghapus
## node player mereka, jadi tiap client menghapus salinan node pemain yang keluar.
func _on_client_left(client_id: int) -> void:
	print("Pemain keluar: ", client_id)
	if _chat_log:
		_chat_log.append_text("[color=#ff6666][i]* %s keluar dari game *[/i][/color]\n" % _display_name(client_id))
	_remove_players_of_client(client_id)

## Hapus semua node pemain milik client_id. Cocokkan lewat variabel tersinkron
## "owner_client_id" (andal), dengan get_gdsync_owner sebagai cadangan.
func _remove_players_of_client(client_id: int) -> void:
	for child in players_container.get_children():
		if _get_node_owner_id(child) == client_id:
			child.queue_free()

## Ambil client id pemilik sebuah node pemain: pakai "owner_client_id" tersinkron
## kalau ada nilainya, kalau belum pakai owner GD-Sync (cadangan).
func _get_node_owner_id(node: Node) -> int:
	var reported: int = -1
	if "owner_client_id" in node:
		reported = int(node.get("owner_client_id"))
	if reported > 0:
		return reported
	return GDSync.get_gdsync_owner(node)

## Sapuan berkala: hapus node pemain yang client-nya sudah TIDAK ada di lobby.
## Ini menutupi sinyal client_left yang telat/tidak terkirim (mis. game ditutup
## paksa lewat Stop editor, atau koneksi putus), sehingga pemain cepat menghilang.
func _sweep_departed_players() -> void:
	if not GDSync.is_active():
		return
	var live_clients: Array = GDSync.lobby_get_all_clients()
	for child in players_container.get_children():
		if not ("owner_client_id" in child):
			continue
		var node_owner: int = int(child.get("owner_client_id"))
		# Lewati yang belum tersinkron (>0) atau node kita sendiri.
		if node_owner <= 0 or node_owner == GDSync.get_client_id():
			continue
		if not live_clients.has(node_owner):
			print("Sapuan: pemain %d sudah keluar, node dihapus." % node_owner)
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
	# Set nama pemain pada node ini lalu SINKRONKAN, supaya label di atas kepala
	# menampilkan nama yang benar di semua client (bukan "Player -1").
	player.set("player_name", _player_name)
	GDSync.sync_var(player, "player_name")
	# Sinkronkan client id pemilik node ini, supaya client lain bisa menghapusnya
	# dengan andal saat kita keluar (owner GD-Sync sering -1 untuk node pemain lain).
	player.set("owner_client_id", client_id)
	GDSync.sync_var(player, "owner_client_id")

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
	# Tempel di sisi KANAN ATAS layar. Memakai anchor (bukan posisi tetap) supaya
	# tetap menempel di kanan atas walau ukuran jendela berubah.
	panel.anchor_left = 1.0
	panel.anchor_top = 0.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 0.0
	panel.offset_left = -(CHAT_PANEL_SIZE.x + CHAT_MARGIN)
	panel.offset_top = CHAT_MARGIN
	panel.offset_right = -CHAT_MARGIN
	panel.offset_bottom = CHAT_MARGIN + CHAT_PANEL_SIZE.y
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
		var sender: String = _display_name(GDSync.get_client_id())
		if GDSync.is_active():
			GDSync.call_func_all(receive_chat_message, sender, msg)
		else:
			receive_chat_message(sender, msg)
	_close_chat()

func receive_chat_message(sender: String, message: String) -> void:
	if _chat_log:
		_chat_log.append_text("[b][color=#55ccff]%s:[/color][/b] %s\n" % [sender, message])

## Nama tampilan untuk sebuah client: pakai username GD-Sync kalau ada,
## kalau belum tersinkron pakai "Player <id>" sebagai cadangan.
func _display_name(client_id: int) -> String:
	return GDSync.player_get_username(client_id, "Player %d" % client_id)
#endregion
