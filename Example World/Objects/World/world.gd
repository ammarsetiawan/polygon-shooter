extends Node3D

const PLAYER_SCENE: PackedScene = preload("res://Player_Controller/player_character.tscn")
const LOBBY_NAME := "FPS_LOBBY"

# Titik spawn dasar. Sama di semua client supaya node sejajar.
const SPAWN_BASE := Vector3(14.9, 2.4, 6.1)

@onready var players_container: Node3D = $PlayersContainer

func _ready() -> void:
	GDSync.connected.connect(_on_connected)
	GDSync.connection_failed.connect(_on_connection_failed)
	GDSync.disconnected.connect(_on_disconnected)
	GDSync.lobby_created.connect(_on_lobby_created)
	GDSync.lobby_creation_failed.connect(_on_lobby_creation_failed)
	GDSync.lobby_joined.connect(_on_lobby_joined)
	GDSync.lobby_join_failed.connect(_on_lobby_join_failed)
	# Izinkan client lain memanggil fungsi visual peluru ini.
	GDSync.expose_func(spawn_projectile_visual)
	# Kadang client menerima node player yang sama dua kali saat join (race di
	# dalam plugin). Kita bereskan duplikatnya tiap ada player baru masuk.
	players_container.child_entered_tree.connect(_on_player_entered)
	# Mulai multiplayer ONLINE lewat server GD-Sync (butuh API key di keys.cfg).
	# Jalankan instance kedua dengan argumen "--client" untuk jadi pemain kedua.
	GDSync.start_multiplayer()

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
	if "--client" in OS.get_cmdline_args():
		GDSync.lobby_join(LOBBY_NAME)
	else:
		GDSync.lobby_create(LOBBY_NAME)

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
	push_error("Gagal bergabung ke lobby %s (error %d)." % [lobby_name, error])

# Hanya membuat player MILIK client ini. GD-Sync menyalinnya ke semua client lain
# dan ke client yang bergabung belakangan (replicate_on_join = true).
func spawn_local_player() -> void:
	var client_id: int = GDSync.get_client_id()

	var player: Node3D = GDSync.multiplayer_instantiate(PLAYER_SCENE, players_container)
	if player == null:
		push_error("Gagal membuat player untuk client %d." % client_id)
		return
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
