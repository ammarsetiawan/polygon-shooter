extends CharacterBody3D

@onready var camera: Node3D = %Camera
@onready var weapon_models: Node3D = $Camera/LeanPivot/MainCamera/Weapons_Manager/Weapons_Models
# Manager senjata (untuk tahu senjata mana yang sedang dipegang).
@onready var weapons_manager: Node = get_node_or_null("Camera/LeanPivot/MainCamera/Weapons_Manager")

@export var subviewport_camera: Camera3D
@export var main_camera:Camera3D
@export var animation_tree: AnimationTree

#region Multiplayer Health
signal health_changed(health: float, max_health: float)

@export_category("Multiplayer Health")
@export var max_health: float = 100.0
var health: float = 100.0:
	set(value):
		var previous: float = health
		health = clampf(value, 0.0, max_health)
		health_changed.emit(health, max_health)
		# Efek HUD: kedipkan vignette merah tiap kali darah berkurang (kena hit).
		if health < previous:
			_damage_flash = 1.0
		# PENTING: deteksi mati/bangkit DI SINI (bukan di Hit_Successful), karena
		# setter ini jalan di SEMUA client. Damage hanya dihitung di client
		# penembak; korban menerima HP baru lewat sync_var -> setter ini -> baru
		# bisa tahu dia mati.
		if health <= 0.0 and not _is_dead:
			_enter_death()
		elif health > 0.0 and _is_dead:
			_exit_death()
#endregion

var death_timer: Timer
var death_timer_label: Control  # Label HUD countdown
var _is_dead: bool = false
var _is_chatting: bool = false
var _death_time_remaining: float = 10.0  # detik sebelum respawn
var _death_timer_elapsed: float = 0.0  # elapsed time for countdown
var _original_collision_mask: int = 1  # untuk dipulihkan setelah respawn
var _death_position: Vector3 = Vector3.ZERO  # posisi saat mati (dipulihkan saat respawn)

var camera_rotation: Vector2 = Vector2(0.0,0.0)
var mouse_sensitivity = 0.001
# --- Recoil (gaya CoD / Delta Force) ---
# Offset recoil yang DITAMBAHKAN ke pandangan, TERPISAH dari bidikan asli pemain
# (camera_rotation). Karena terpisah, begitu pemain berhenti menembak pandangan
# otomatis kembali ke bidikan semula - tidak "nyangkut" seperti recoil permanen.
# x = yaw (ke kanan +), y = pitch (ke bawah +).
var _recoil_offset: Vector2 = Vector2.ZERO
# Waktu sejak tembakan terakhir; pemulihan recoil baru mulai setelah jeda ini,
# jadi menembak terus-menerus membuat pandangan terus naik (climb).
var _recoil_time_since_shot: float = 999.0
const RECOIL_MAX_OFFSET := 0.45  # rad (~26 derajat) batas aman tiap sumbu
# --- Efek HUD saat terkena hit (vignette merah di pinggir layar) ---
var _damage_overlay: Control
var _damage_flash: float = 0.0      # 0..1, meluruh cepat tiap kali kena hit
var _damage_intensity: float = 0.0  # nilai terhalus yang dikirim ke shader
var _damage_spread: float = 0.0
const DAMAGE_FLASH_DECAY := 2.2     # per detik (1.0 -> 0 dalam ~0.45 detik)
# Interest management GD-Sync (dibuat dari kode di _create_interest_nodes).
var interest_viewer: InterestViewer
var interest_object: InterestObject
var crouched: bool = false
var crouch_blocked: bool = false
var is_aiming: bool = false
@export var aim_fov: float = 40.0
var default_fov: float = 75.0

@export_category("Crouch Parametres")
@export var enable_crouch: bool = true
@export var crouch_toggle: bool = false
@export var crouch_collision: ShapeCast3D
@export_range(0.0,3.0) var crouch_speed_reduction = 2.0
@export_range(0.0,0.50) var crouch_blend_speed = .2
enum {GROUND_CROUCH = -1, STANDING = 0, AIR_CROUCH = 1}

@export_category("Lean Parametres")
@export var enable_lean: bool = true
@export_range(0.0,1.0) var lean_speed: float = .2
@export var right_lean_collision: ShapeCast3D
@export var left_lean_collision: ShapeCast3D
var lean_tween
enum {LEFT = 1, CENTRE = 0, RIGHT = -1}

@export_category("speed Parameters")
@export var enable_sprint: bool = true
## Kalau aktif: tekan Shift SEKALI untuk mengaktifkan sprint (tidak perlu ditahan).
## Berguna kalau keyboard "ghosting" saat menahan Shift + W sambil menekan lompat
## (tombol lompat tidak sampai ke game). Bawaan: mati (= tahan Shift seperti biasa).
@export var sprint_toggle: bool = false
@export var sprint_timer: Timer
@export var sprint_cooldown_time: float = 3.0
@export var sprint_time: float = 1.0
@export var sprint_replenish_rate: float = 0.30
## Kecepatan lari normal dalam meter/detik (CoD ~4,6).
@export var move_speed: float = 4.8
## Percepatan menapak tanah (m/s^2). 60 = kecepatan penuh dalam ~0,08 s:
## responsif tapi tidak terasa "robotik"/menyentak.
@export var ground_acceleration: float = 60.0
## Perlambatan saat tombol gerak dilepas. SENGAJA lebih besar dari percepatan
## supaya berhenti terasa "crisp" ala CoD -- tidak meluncur/keset saat strafe.
@export var ground_deceleration: float = 70.0
## Percepatan di udara (air control). Cukup supaya arah lompatan masih bisa
## dikoreksi, tapi tidak sebesar di tanah.
@export var air_acceleration: float = 20.0
var sprint_on_cooldown: bool = false
var sprint_time_remaining: float = sprint_time
@onready var sprint_bar: Range = $CanvasLayer/SprintBar

const NORMAL_speed = 1
## Pengali kecepatan saat sprint (4,8 x 1,6 = 7,7 m/s).
@export_range(1.0,3.0) var sprint_speed: float = 1.6
## Pengali kecepatan saat jalan pelan / walk (Ctrl).
@export_range(0.1,1.0) var walk_speed: float = 0.55
var speed_modifier: float = NORMAL_speed
## Status sprint saat memakai mode "Sprint Toggle".
var _sprint_latched: bool = false

@export_category("Jump Parameters")
@export var coyote_timer: Timer
@export var jump_peak_time: float = .34
@export var jump_fall_time: float = .32
@export var jump_height: float = 1.05
@export var jump_distance: float = 4.0
@export var coyote_time: float = .1
@export var jump_buffer_time: float = .2

@export_category("Camera Feel (rasa ala CoD)")
## Tambahan FOV saat sprint supaya terasa "kencang". 0 = matikan.
@export var sprint_fov_kick: float = 7.0
## Seberapa cepat FOV mengejar targetnya.
@export var fov_lerp_speed: float = 8.0
## Tinggi gerakan naik-turun kepala saat berjalan (meter). 0 = matikan.
@export var bob_height: float = 0.035
## Frekuensi langkah head-bob (langkah/detik) pada kecepatan penuh.
@export var bob_frequency: float = 1.8
## Kedalaman kamera turun saat mendarat, per (m/s) kecepatan jatuh.
@export var landing_dip_scale: float = 0.022
@export var landing_dip_max: float = 0.16
## Seberapa cepat kamera pulih dari landing dip.
@export var landing_dip_recover: float = 10.0

# --- Scope bidik (digambar dari kode lewat shader, tanpa PNG) ---
@export_group("Scope")
@export_range(0.2, 0.6) var scope_lens_radius: float = 0.44
@export_range(0.02, 0.25) var scope_ring_thickness: float = 0.08
@export var scope_ring_color: Color = Color(0.55, 0.55, 0.57)
@export_range(0.0, 1.0) var scope_ring_alpha: float = 0.9
@export var scope_bg_color: Color = Color(0.0, 0.0, 0.0)
@export_range(0.0, 1.0) var scope_bg_alpha: float = 1.0
@export_range(0.0005, 0.006) var scope_line_thickness: float = 0.0016
@export_range(0.0, 0.4) var scope_line_start: float = 0.08
@export_range(0.3, 1.0) var scope_line_end: float = 0.92
@export var scope_reticle_color: Color = Color(0.10, 0.10, 0.10)
@export_range(0.0, 1.0) var scope_reticle_alpha: float = 0.9
@export_range(0.001, 0.02) var scope_center_dot_size: float = 0.0045
@export var scope_center_dot_color: Color = Color(0.85, 0.15, 0.15)
@export_group("")

# --- Efek HUD saat terkena hit (vignette merah di pinggir layar) ---
@export_group("Damage HUD")
@export var damage_tint: Color = Color(0.75, 0.0, 0.0)
## Kekuatan kedipan merah tepat saat terkena hit.
@export var damage_flash_intensity: float = 0.75
## Seberapa jauh kedipan merah menjalar ke tengah layar (0..1).
@export var damage_flash_spread: float = 0.35
## Kekuatan merah saat darah hampir habis.
@export var damage_low_health_intensity: float = 0.55
## Seberapa jauh merah menjalar saat darah hampir habis (0..1).
@export var damage_low_health_spread: float = 0.85
## Kecepatan peralihan nilai merah (makin besar makin instan).
@export var damage_fade_speed: float = 3.0
@export_group("")

# --- Interest management (GD-Sync) ---
# Membatasi berapa banyak data pemain yang dikirim ke tiap client + menyembunyikan
# model pemain yang jauh supaya tidak ikut dirender (tidak ada draw call, bayangan,
# maupun animasi untuk mereka). Ini yang membuat lobby banyak pemain tetap ringan.
@export_group("Interest")
## Radius (meter) di mana pemain lain masih menerima state pemain ini dan modelnya
## masih tampil. Di luar radius + margin, state berhenti dikirim dan model
## disembunyikan di client tersebut.
@export var interest_visibility_radius: float = 60.0
## Jarak tambahan sebelum pemain dianggap keluar radius (mencegah kedip saat di tepi).
@export var interest_exit_margin: float = 20.0
## Seberapa sering posisi pemain ini dilaporkan ke host untuk pengecekan jarak (Hz).
@export var interest_viewer_update_rate: float = 4.0
## Jarak (meter) di mana model pemain LAIN berhenti dirender di client kita.
## Godot sudah membuang objek di luar kerucut kamera (frustum culling) sendiri;
## ini untuk pemain yang JAUH tapi masih di dalam kerucut kamera - node-nya
## disembunyikan sehingga tidak ada draw call, bayangan, maupun animasi.
@export var interest_hide_distance: float = 80.0
@export_group("")

# Get the gravity from the project settings to be synced with RigidBody nodes.
var jump_gravity = ProjectSettings.get_setting("physics/3d/default_gravity")
var fall_gravity: float
var jump_velocity: float
var base_speed: float 
var _speed: float 
var jump_available: bool = true
var jump_buffer: bool = false

# --- State untuk Camera Feel (head-bob, landing dip, FOV sprint) ---
var _fov_target: float = 75.0
var _bob_phase: float = 0.0
var _bob_amp: float = 0.0
var _land_dip: float = 0.0
var _fall_speed: float = 0.0
var _prev_on_floor: bool = true
# Permintaan lompat yang dicatat di _input, diproses di _physics_process.
var _jump_requested: bool = false

var _is_local: bool = true
var _weapon_viewmodel_hidden: bool = false
# Overlay scope prosedural (dibuat dari kode + shader, tanpa PNG) pada CanvasLayer HUD.
var _scope_overlay: Control
# Label3D melayang di atas kepala yang menampilkan nama pemain.
var name_label: Label3D
# Nama pemain ini, DISINKRONKAN ke semua client lewat GDSync (expose_var/sync_var).
# Karena node pemain lain tidak bisa dibaca client id-nya (owner = -1), nama
# dikirim sebagai variabel tersinkron pada node player itu sendiri.
var player_name: String = "Player":
	set(value):
		player_name = value
		_update_name_label_text()
# Client id pemilik node ini, DISINKRONKAN ke semua client. Dipakai world.gd untuk
# menghapus node pemain yang keluar dengan andal: get_gdsync_owner() sering
# mengembalikan -1 untuk node pemain LAIN, jadi owner tidak bisa diandalkan.
var owner_client_id: int = -1
const WEAPON_VIEWMODEL_RAY := 0.9
const WEAPON_VISUAL_LAYER := 524288
const WORLD_VISUAL_LAYER := 1
# Shader scope prosedural (digambar dari kode, tanpa tekstur PNG).
const SCOPE_SHADER := preload("res://Player_Controller/HUD ASSETS/scope_overlay.gdshader")
# Shader vignette merah efek terkena hit (juga digambar dari kode).
const DAMAGE_SHADER := preload("res://Player_Controller/HUD ASSETS/damage_overlay.gdshader")

func _ready() -> void:
	# HP: semua player masuk group "Target" supaya peluru bisa mengenainya.
	# "health" di-expose agar bisa disinkronkan ke semua client.
	health = max_health
	add_to_group("Target")
	GDSync.expose_var(self, "health")
	# Nama pemain disinkronkan ke semua client (untuk label di atas kepala).
	GDSync.expose_var(self, "player_name")
	# Client id pemilik, disinkronkan supaya node pemain yang keluar bisa dihapus
	# segera (tidak bergantung pada get_gdsync_owner yang sering -1).
	GDSync.expose_var(self, "owner_client_id")
	# Fungsi untuk memicu animasi tubuh (jongkok / miring) di client lain.
	GDSync.expose_func(_remote_set_blend)
	update_camera_rotation()
	calculate_movement_parameters()
	# FOV mulai dari nilai default; dihaluskan tiap frame di _update_camera_feel
	# (dipakai bersama oleh aim & sprint supaya tidak ada dua tween yang bentrok).
	_fov_target = default_fov
	if main_camera:
		main_camera.fov = default_fov
	# Tentukan apakah instance ini milik client lokal (dikendalikan) atau milik
	# pemain lain (cuma ditampilkan). Owner bisa di-set sesaat setelah node ini
	# dibuat, jadi kita reaksikan juga perubahannya.
	GDSync.connect_gdsync_owner_changed(self, _on_gdsync_owner_changed)
	_create_scope_overlay()
	_create_damage_overlay()
	_create_interest_nodes()
	_apply_network_role()
	# Inisialisasi death timer
	death_timer = $DeathTimer
	death_timer.timeout.connect(_on_death_timer_timeout)
	# Buat Label countdown HUD
	death_timer_label = Label.new()
	death_timer_label.name = "DeathTimerLabel"
	death_timer_label.text = "3"
	death_timer_label.visible = false
	death_timer_label.add_theme_font_size_override("font_size", 96)
	death_timer_label.add_theme_color_override("font_color", Color(1, 0.2, 0.2))
	death_timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	death_timer_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	get_node("CanvasLayer").add_child(death_timer_label)
	# Simpan collision mask awal supaya bisa dipulihkan setelah respawn.
	_original_collision_mask = collision_mask

func _on_gdsync_owner_changed(_owner: int) -> void:
	_apply_network_role()

## Matikan/nyalakan pemrosesan input pada node ini dan SEMUA turunannya.
## Penting: kalau hanya parent yang dimatikan, anak node yang punya _input
## sendiri (mis. Weapon_State_Machine) tetap menerima input keyboard.
func _set_input_enabled_recursive(node: Node, enabled: bool) -> void:
	node.set_process_input(enabled)
	node.set_process_unhandled_input(enabled)
	node.set_process_unhandled_key_input(enabled)
	for child in node.get_children():
		_set_input_enabled_recursive(child, enabled)

## Atur visual layer semua mesh viewmodel senjata.
## - Player lokal  : layer WEAPON_VISUAL_LAYER (dirender overlay SubViewport, first-person).
## - Player lawan  : layer WORLD_VISUAL_LAYER (dirender sebagai objek dunia biasa,
##                   jadi terlihat "memegang senjata" dari sudut pandang kita dan
##                   tetap tertutup dinding dengan benar).
func _set_viewmodel_layers(node: Node, layers: int) -> void:
	if node is MeshInstance3D:
		(node as MeshInstance3D).layers = layers
	for child in node.get_children():
		_set_viewmodel_layers(child, layers)

## Dijalankan pada SALINAN player ini di client LAIN: putar ulang perubahan blend
## animasi tubuh (jongkok / miring) supaya terlihat di layar mereka.
func _remote_set_blend(param_path: String, value: float, speed: float) -> void:
	if _is_local or animation_tree == null:
		return
	var blend_tween := get_tree().create_tween()
	blend_tween.tween_property(animation_tree, "parameters/" + param_path + "/blend_amount", value, speed)

func _apply_network_role() -> void:
	if not is_inside_tree():
		return
	_is_local = GDSync.get_gdsync_owner(self) == GDSync.get_client_id()
	# Input harus dimatikan SECARA REKURSIF, bukan cuma di root. Node anak
	# (Weapon_State_Machine) punya _input sendiri; kalau tidak, player lawan
	# ikut menembak saat kita menekan tombol.
	_set_input_enabled_recursive(self, _is_local)
	set_process(_is_local)
	set_physics_process(_is_local)

	# HUD + viewmodel senjata keduanya ada di dalam CanvasLayer (HUD dan senjata
	# dirender lewat SubViewport di bawahnya), jadi keduanya di-toggle bersamaan.
	var hud: CanvasLayer = $CanvasLayer
	if hud:
		hud.visible = _is_local

	if _is_local:
		if main_camera:
			main_camera.current = true
		if weapon_models:
			_set_viewmodel_layers(weapon_models, WEAPON_VISUAL_LAYER)
			weapon_models.visible = true
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	else:
		# Player milik pemain lain: matikan kamera supaya tidak mencuri tampilan.
		if main_camera:
			main_camera.current = false
		# Label nama dibuat HANYA untuk pemain lain. Pemain lokal tidak perlu label
		# (dulu selalu dibuat walau disembunyikan) dan tiap Label3D menyimpan
		# tekstur teksnya sendiri - jadi kita hemat satu tekstur teks per client.
		if not is_instance_valid(name_label):
			_create_name_label()
		if weapon_models:
			# Tampilkan senjata lawan di layer dunia supaya terlihat "dipegang",
			# bukan melayang menembus dinding lewat overlay SubViewport.
			_set_viewmodel_layers(weapon_models, WORLD_VISUAL_LAYER)
			weapon_models.visible = true
	
	# Nama di atas kepala hanya untuk pemain LAIN (kita tidak perlu melihat nama sendiri).
	if is_instance_valid(name_label):
		name_label.visible = not _is_local
		_update_name_label_text()

	# Fitur mahal yang hanya dibutuhkan pemain lokal (lihat penjelasan fungsinya).
	_apply_local_only_features(_is_local)

## ShapeCast3D (lean/crouch/melee) hanya dipakai oleh pemain LOKAL.
## Pemain lain tidak perlu mengeceknya tiap frame fisika.
const _LOCAL_ONLY_SHAPECASTS: Array[String] = [
	"CrouchCollider",
	"Camera/LeanLeftCollision",
	"Camera/LeanRighCollision",
	"Camera/LeanPivot/MainCamera/Weapons_Manager/Melee_Hitbox",
]

## Nyalakan/matikan fitur yang HANYA dibutuhkan pemain lokal.
## Fitur ini MAHAL per pemain, jadi kalau dibiarkan aktif di semua pemain,
## FPS turun makin banyak pemain masuk (SubViewport merender scene 3D ekstra
## tiap frame, ShapeCast3D di-update tiap frame fisika, Area3D pickup memantau).
func _apply_local_only_features(local: bool) -> void:
	# SubViewport viewmodel: di pemain lain, matikan render 3D ekstra per pemain.
	var sub_container: SubViewportContainer = get_node_or_null("CanvasLayer/SubViewportContainer")
	if sub_container:
		sub_container.visible = local
	var sub_vp: SubViewport = get_node_or_null("CanvasLayer/SubViewportContainer/SubViewport")
	if sub_vp:
		sub_vp.render_target_update_mode = (
			SubViewport.UPDATE_ALWAYS if local else SubViewport.UPDATE_DISABLED)
	var sub_cam: Camera3D = get_node_or_null("CanvasLayer/SubViewportContainer/SubViewport/Camera3D")
	if sub_cam:
		sub_cam.current = local
	# ShapeCast3D only run for the local player.
	for path in _LOCAL_ONLY_SHAPECASTS:
		var shapecast: ShapeCast3D = get_node_or_null(path)
		if shapecast:
			shapecast.enabled = local
	# Pickup detection hanya berguna untuk pemain lokal.
	var pickup: Area3D = get_node_or_null("PickUpDetection")
	if pickup:
		pickup.monitoring = local

## Membuat Label3D nama melayang di atas kepala (dibuat via kode).
func _create_name_label() -> void:
	name_label = Label3D.new()
	name_label.name = "NameLabel"
	name_label.text = "Player"
	# Font/outline sekecil mungkin: tiap Label3D menyimpan tekstur teksnya sendiri,
	# jadi ukuran besar = memori + kerja GPU ekstra PER PEMAIN.
	name_label.font_size = 32
	name_label.pixel_size = 0.0045
	name_label.outline_size = 5
	name_label.modulate = Color(1, 1, 1, 1)
	name_label.outline_modulate = Color(0, 0, 0, 0.85)
	name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	name_label.no_depth_test = false
	name_label.position = Vector3(0, 2.0, 0)
	name_label.visible = false
	add_child(name_label)
	_update_name_label_text()

## Perbarui teks label dari variabel player_name (yang tersinkron).
func _update_name_label_text() -> void:
	if not is_instance_valid(name_label):
		return
	var n: String = player_name.strip_edges()
	var t: String = n if n != "" else "Player"
	# Hanya tulis ulang kalau teksnya BERUBAH: set_text pada Label3D membuat ulang
	# tekstur teksnya, dan setter "player_name" bisa terpanggil berulang kali.
	if name_label.text != t:
		name_label.text = t
	
## Dipanggil oleh peluru/proyektil di client penembak saat mengenai player ini.
## HP diubah pada salinan node ini (client penembak) lalu disinkronkan, sehingga
## semua client (termasuk korban) melihat HP yang sama.
func Hit_Successful(damage, _direction: Vector3 = Vector3.ZERO, _position: Vector3 = Vector3.ZERO) -> void:
	health -= damage
	GDSync.sync_var(self, "health")

## Menyembunyikan pemain di client ini (dipanggil dari setter "health").
## Otak memutuskan ini di SEMUA client, jadi pemain mati menghilang di mana-mana.
func _enter_death() -> void:
	_is_dead = true
	weapon_models.visible = false
	# Bekukan posisi: collision dimatikan, jadi gravitasi TIDAK boleh jalan,
	# kalau tidak pemain akan jatuh menembus lantai selama mati.
	_death_position = global_position
	velocity = Vector3.ZERO
	set_physics_process(false)
	collision_mask = 0
	visible = false
	# Countdown + timer respawn hanya untuk pemain yang kita kendalikan lokal.
	if _is_local:
		death_timer_label.visible = true
		death_timer_label.text = "3"
		_death_timer_elapsed = 0.0
		death_timer.start(_death_time_remaining)
	
	# MATIHIN INPUT SAAT MATI (mencegah menembak saat mati)
	_set_input_enabled_recursive(self, false)

## Menampilkan kembali pemain saat HP sudah di atas 0 (respawn).
func _exit_death() -> void:
	_is_dead = false
	visible = true
	weapon_models.visible = true
	collision_mask = _original_collision_mask
	# Kembalikan ke posisi saat mati dan pastikan fisika hidup lagi.
	global_position = _death_position
	velocity = Vector3.ZERO
	set_physics_process(_is_local)
	if _is_local:
		death_timer_label.visible = false
		_death_timer_elapsed = 0.0
	
	# AKTIFKAN KEMBALI INPUT SAAT RESPAWN
	_set_input_enabled_recursive(self, not _is_chatting)

func set_chat_active(active: bool) -> void:
	_is_chatting = active
	if _is_local and not _is_dead:
		_set_input_enabled_recursive(self, not active)
		if active:
			velocity.x = 0.0
			velocity.z = 0.0
			exit_sprint()

func _respawn() -> void:
	# Set HP penuh; setter "health" yang akan memanggil _exit_death.
	health = max_health
	GDSync.sync_var(self, "health")

func update_camera_rotation() -> void:
	var current_rotation = get_rotation()
	camera_rotation.x = current_rotation.y
	camera_rotation.y = current_rotation.x
	
	
func _input(event: InputEvent) -> void:
	if _is_dead or _is_chatting:
		return
	# Lompat: catat PERMINTAAN di sini (event-driven), diproses di _physics_process.
	# Input.is_action_just_pressed() di _physics_process bisa terlewat / dobel saat
	# FPS rendah (GPU lemah) sehingga lompat terasa "bandel"; event-driven andal.
	if event.is_action_pressed("jump"):
		_jump_requested = true
	# Mode Sprint Toggle: tekan Shift sekali = nyala/mati (geser, tidak ditahan).
	if sprint_toggle and event.is_action_pressed("sprint"):
		_sprint_latched = not _sprint_latched
	if event.is_action_pressed("ui_cancel"):
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		
	if event is InputEventMouseMotion:
		var MouseEvent = event.relative * mouse_sensitivity
		camera_look(MouseEvent)
	
	if enable_crouch:
		if event.is_action_pressed("crouch"):
			crouch()
		if event.is_action_released("crouch"):
			if !crouch_toggle and crouched:
				crouch()
	
	if enable_lean:
		if Input.is_action_just_released("lean_left") or Input.is_action_just_released("lean_right"):
			if !(Input.is_action_pressed("lean_right") or Input.is_action_pressed("lean_left")):
				lean(CENTRE)
		if Input.is_action_just_pressed("lean_left"):
			lean(LEFT)
		if Input.is_action_just_pressed("lean_right"):
			lean(RIGHT)

	# Bidik (RMB) TIDAK diatur di sini lagi -- dihitung dari poll tiap frame di
	# _update_aim_state() supaya tidak bergantung pada event tekan/lepas yang
	# bisa terlewat (sama seperti kasus sprint).
		
	if enable_sprint:
		# Sprint/jalan TIDAK diatur dari event tekan/lepas di sini lagi.
		# Kecepatannya dihitung ulang tiap frame fisika di _physics_process,
		# supaya satu event "lepas" yang hilang (pemain mati / buka chat /
		# jendela kehilangan fokus) tidak membuat pemain nyangkut di mode
		# sprint/jalan selamanya.
		pass

func calculate_movement_parameters() -> void:
	jump_gravity = (2*jump_height)/pow(jump_peak_time,2)
	fall_gravity = (2*jump_height)/pow(jump_fall_time,2)
	jump_velocity = jump_gravity * jump_peak_time
	# Kecepatan dasar TIDAK lagi diturunkan dari parameter lompatan (dulu
	# jump_distance / total waktu lompatan = 4 m/s). Dulu menyetel lompatan ikut
	# mengubah kecepatan lari, sehingga sulit terasa enak. Sekarang eksplisit.
	base_speed = move_speed
	_speed = base_speed

func lean(blend_amount: int) -> void:
	if is_on_floor():
		if lean_tween:
			lean_tween.kill()
		
		lean_tween = get_tree().create_tween()
		lean_tween.tween_property(animation_tree,"parameters/lean_blend/blend_amount", blend_amount, lean_speed)
		# Sinkronkan ke client lain supaya animasi miring terlihat di sana.
		GDSync.call_func(_remote_set_blend, "lean_blend", float(blend_amount), lean_speed)

func lean_collision() -> void:
	animation_tree["parameters/left_collision_blend/blend_amount"] = lerp(
		float(animation_tree["parameters/left_collision_blend/blend_amount"]),float(left_lean_collision.is_colliding()),lean_speed
	)
	animation_tree["parameters/right_collision_blend/blend_amount"] = lerp(
		float(animation_tree["parameters/right_collision_blend/blend_amount"]),float(right_lean_collision.is_colliding()),lean_speed
	)

func crouch() -> void:
	var Blend
	if !crouch_collision.is_colliding():
		if crouched:
			Blend = STANDING
		else:
			speed_modifier = NORMAL_speed
			exit_sprint()
			
			if is_on_floor():
				Blend = GROUND_CROUCH
			else:
				Blend = AIR_CROUCH
		var blend_tween = get_tree().create_tween()
		blend_tween.tween_property(animation_tree,"parameters/Crouch_Blend/blend_amount",Blend,crouch_blend_speed)
		# Sinkronkan ke client lain supaya animasi jongkok terlihat di sana.
		GDSync.call_func(_remote_set_blend, "Crouch_Blend", float(Blend), crouch_blend_speed)
		crouched = !crouched
	else:
		crouch_blocked = true

func camera_look(Movement: Vector2) -> void:
	# Sensitivitas diperkecil saat memakai scope ber-zoom (lihat _scope_look_scale).
	camera_rotation += Movement * _scope_look_scale()
	_apply_camera_rotation()

## Terapkan sudut pandang = input mouse (camera_rotation) + offset recoil.
## Dipanggil juga tiap frame oleh _update_recoil supaya pemulihan recoil terlihat
## halus tanpa pemain harus menggerakkan mouse.
func _apply_camera_rotation() -> void:
	
	transform.basis = Basis()
	camera.transform.basis = Basis()
	
	camera_rotation.y = clamp(camera_rotation.y, -1.5, 1.2)
	var total: Vector2 = camera_rotation + _recoil_offset
	total.y = clamp(total.y, -1.5, 1.2)

	rotate_object_local(Vector3(0,1,0), -total.x) # first rotate in Y
	camera.rotate_object_local(Vector3(1,0,0), -total.y) # then rotate in X
	
## Dipanggil senjata setiap kali menembak (lihat Weapon_State_Machine.shoot).
## vertical_deg = dorongan pandangan KE ATAS, horizontal_deg = simpangan acak kiri/kanan.
## Pengali ADS / jongkok diambil dari WeaponResource senjata yang sedang dipakai.
func add_recoil(vertical_deg: float, horizontal_deg: float) -> void:
	if _is_dead or _is_chatting:
		return
	var mult: float = 1.0
	var w: WeaponResource = _current_weapon_resource()
	if w != null:
		if is_aiming:
			mult *= w.recoil_ads_multiplier
		if crouched:
			mult *= w.recoil_crouch_multiplier
	_recoil_offset.x = clampf(_recoil_offset.x + deg_to_rad(horizontal_deg) * mult, -RECOIL_MAX_OFFSET, RECOIL_MAX_OFFSET)
	_recoil_offset.y = clampf(_recoil_offset.y - deg_to_rad(vertical_deg) * mult, -RECOIL_MAX_OFFSET, RECOIL_MAX_OFFSET)
	_recoil_time_since_shot = 0.0
	_apply_camera_rotation()

## Pemulihan recoil: setelah jeda, pandangan kembali ke bidikan semula dengan
## kecepatan tetap (diatur per senjata di WeaponResource). Offsetnya TERPISAH dari
## camera_rotation, jadi bidikan asli pemain tidak pernah ikut bergeser.
func _update_recoil(delta: float) -> void:
	if _recoil_offset.is_zero_approx():
		return
	_recoil_time_since_shot += delta
	var w: WeaponResource = _current_weapon_resource()
	var delay: float = w.recoil_recovery_delay if w != null else 0.12
	if _recoil_time_since_shot < delay:
		return
	var speed: float = w.recoil_recovery_speed if w != null else 14.0
	_recoil_offset = _recoil_offset.move_toward(Vector2.ZERO, deg_to_rad(speed) * delta)
	_apply_camera_rotation()

func exit_sprint() -> void:
	_sprint_latched = false
	if !sprint_timer.is_stopped():
		sprint_time_remaining = sprint_timer.time_left
		sprint_timer.stop()

func sprint_replenish(delta) -> void:
	var sprint_bar_Value

	if !sprint_on_cooldown and (speed_modifier != sprint_speed):
		
		if is_on_floor():
			sprint_time_remaining = move_toward(sprint_time_remaining, sprint_time, delta*sprint_replenish_rate)
			
		sprint_bar_Value= (sprint_time_remaining/sprint_time)*100
		
	else:
		sprint_bar_Value = (sprint_timer.time_left/sprint_time)*100
	
	sprint_bar.value = sprint_bar_Value
	
	if sprint_bar_Value == 100:
		sprint_bar.hide()
	else:
		sprint_bar.show()

func _process(_delta: float) -> void:
	_update_aim_state()
	_update_camera_feel(_delta)
	_update_recoil(_delta)
	_update_scope()
	_update_damage_overlay(_delta)
	_update_remote_player_culling()
	if subviewport_camera:
		subviewport_camera.global_transform = main_camera.global_transform
	_update_weapon_occlusion()
	# Update countdown HUD "3, 2, 1". HANYA mengubah teks label; jangan pernah
	# mengubah _is_dead di sini. Timer (_on_death_timer_timeout -> _respawn) yang
	# bertanggung jawab membangkitkan pemain lewat _exit_death. Kalau _process
	# ikut men-set _is_dead=false, setter "health" mengira sudah hidup lagi dan
	# _exit_death tidak pernah jalan (pemain tetap tak terlihat & tak bisa gerak).
	if _is_dead and death_timer_label.visible:
		_death_timer_elapsed += _delta
		var remaining: float = _death_time_remaining - _death_timer_elapsed
		var count: int = maxi(1, ceili(remaining))
		death_timer_label.text = str(count)
		# Center horizontally, near the top of the screen.
		var canvas_size: Vector2 = get_viewport().get_visible_rect().size
		death_timer_label.size = Vector2(canvas_size.x, 120)
		death_timer_label.position = Vector2(0, canvas_size.y * 0.25)

## Interest management GD-Sync, dibuat dari KODE supaya tidak hilang kalau scene
## di-save ulang oleh editor.
##
## Cara kerjanya:
##  - "InterestViewer" melaporkan posisi pemain LOCAL ke host beberapa kali per
##    detik, supaya host tahu siapa sedang berada di dekat siapa.
##  - "InterestObject" menandai pemain ini: state-nya (posisi, rotasi, HP) hanya
##    dikirim ke client yang pemainnya berada dalam `interest_visibility_radius`.
##    Dengan `hide_parent_out_of_range`, di client yang jauh node pemain ini
##    DISEMBUNYIKAN - jadi tidak ikut dirender (tanpa draw call, bayangan, dan
##    animasi). Pemain yang sedang dipegang sendiri tidak pernah disembunyikan.
## Sembunyikan pemain lain yang terlalu JAUH supaya tidak ikut dirender.
## (Godot sudah melakukan frustum culling untuk objek di luar kamera; ini untuk
## pemain jauh yang masih di dalam kerucut kamera.) Menyembunyikan node-nya juga
## menghentikan animasi & label namanya, jadi makin banyak pemain tetap ringan.
func _update_remote_player_culling() -> void:
	for p in get_tree().get_nodes_in_group("Target"):
		if p == self or not is_instance_valid(p):
			continue
		var too_far: bool = global_position.distance_to(p.global_position) > interest_hide_distance
		if (not p.visible) != too_far:
			p.visible = not too_far

func _create_interest_nodes() -> void:
	interest_viewer = InterestViewer.new()
	interest_viewer.name = "InterestViewer"
	interest_viewer.update_rate = interest_viewer_update_rate
	add_child(interest_viewer)

	interest_object = InterestObject.new()
	interest_object.name = "InterestObject"
	interest_object.visibility_radius = interest_visibility_radius
	interest_object.exit_margin = interest_exit_margin
	interest_object.update_rate = 3.0
	# Sengaja TIDAK memakai hide_parent_out_of_range: penyembunyian itu bergantung
	# pada daftar penerima dari host, dan kalau daftarnya belum terhitung pemain
	# lain bisa hilang dari layar. Penyembunyian pemain jauh ditangani sendiri di
	# _update_remote_player_culling() supaya aman & bisa diatur.
	interest_object.hide_parent_out_of_range = false
	add_child(interest_object)
## supaya tidak ikut terhapus kalau scene di-save ulang oleh editor.
func _create_damage_overlay() -> void:
	var hud: CanvasLayer = get_node_or_null("CanvasLayer")
	if hud == null:
		return
	var rect := ColorRect.new()
	rect.name = "DamageOverlay"
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = DAMAGE_SHADER
	mat.set_shader_parameter("tint", damage_tint)
	rect.material = mat
	rect.visible = false
	# Ditambahkan PALING AKHIR supaya tergambar DI ATAS overlay scope juga.
	hud.add_child(rect)
	_damage_overlay = rect

## Perbarui vignette merah tiap frame:
##  - kedipan singkat saat baru terkena hit (_damage_flash meluruh cepat),
##  - makin sedikit darah, merahnya makin kuat DAN makin meluas ke tengah layar.
func _update_damage_overlay(delta: float) -> void:
	if _damage_overlay == null:
		return
	if _damage_flash > 0.0:
		_damage_flash = maxf(_damage_flash - DAMAGE_FLASH_DECAY * delta, 0.0)

	var missing: float = 1.0 - clampf(health / maxf(max_health, 0.001), 0.0, 1.0)
	var want_intensity: float = damage_low_health_intensity * missing + damage_flash_intensity * _damage_flash
	var want_spread: float = damage_low_health_spread * missing + damage_flash_spread * _damage_flash

	var t: float = clampf(damage_fade_speed * delta, 0.0, 1.0)
	_damage_intensity = lerpf(_damage_intensity, want_intensity, t)
	_damage_spread = lerpf(_damage_spread, want_spread, t)

	_damage_overlay.visible = _is_local and _damage_intensity > 0.002
	if not _damage_overlay.visible:
		return
	var mat: ShaderMaterial = _damage_overlay.material
	mat.set_shader_parameter("intensity", clampf(_damage_intensity, 0.0, 1.0))
	mat.set_shader_parameter("spread", clampf(_damage_spread, 0.0, 1.0))

## Buat overlay scope PROSEDURAL dari KODE, bukan dari .tscn/PNG, supaya tidak
## ikut terhapus kalau scene di-save ulang oleh editor.
func _create_scope_overlay() -> void:
	var hud: CanvasLayer = get_node_or_null("CanvasLayer")
	if hud == null:
		return
	var rect := ColorRect.new()
	rect.name = "ScopeOverlay"
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Warna ColorRect diabaikan: shader menulis COLOR sendiri (transparan di lensa).
	var mat := ShaderMaterial.new()
	mat.shader = SCOPE_SHADER
	rect.material = mat
	rect.visible = false
	# Ditambahkan PALING AKHIR supaya tergambar DI ATAS viewmodel senjata
	# (viewmodel dirender lewat SubViewportContainer di dalam CanvasLayer ini).
	hud.add_child(rect)
	rect.resized.connect(_update_scope_shader_size)
	_scope_overlay = rect
	_apply_scope_shader_params()
	_update_scope_shader_size()

## Kirim semua nilai export scope ke uniform shader.
func _apply_scope_shader_params() -> void:
	if _scope_overlay == null:
		return
	var mat: ShaderMaterial = _scope_overlay.material
	mat.set_shader_parameter("lens_radius", scope_lens_radius)
	mat.set_shader_parameter("ring_thickness", scope_ring_thickness)
	mat.set_shader_parameter("ring_color", scope_ring_color)
	mat.set_shader_parameter("ring_alpha", scope_ring_alpha)
	mat.set_shader_parameter("bg_color", scope_bg_color)
	mat.set_shader_parameter("bg_alpha", scope_bg_alpha)
	mat.set_shader_parameter("line_frac", scope_line_thickness)
	mat.set_shader_parameter("line_start", scope_line_start)
	mat.set_shader_parameter("line_end", scope_line_end)
	mat.set_shader_parameter("reticle_color", scope_reticle_color)
	mat.set_shader_parameter("reticle_alpha", scope_reticle_alpha)
	mat.set_shader_parameter("dot_frac", scope_center_dot_size)
	mat.set_shader_parameter("dot_color", scope_center_dot_color)

## Shader bekerja dalam koordinat piksel, jadi ukuran layar harus dikirim ulang
## setiap kali jendela berubah ukuran (kalau tidak, lingkaran scope jadi lonjong).
func _update_scope_shader_size() -> void:
	if _scope_overlay == null:
		return
	var sz: Vector2 = _scope_overlay.size
	if sz.x < 1.0 or sz.y < 1.0:
		sz = get_viewport().get_visible_rect().size
	(_scope_overlay.material as ShaderMaterial).set_shader_parameter("screen_size", sz)

## Senjata yang sedang dipegang (WeaponResource), atau null.
func _current_weapon_resource() -> WeaponResource:
	if weapons_manager == null:
		return null
	var slot: WeaponSlot = weapons_manager.get("current_weapon_slot")
	if slot == null:
		return null
	return slot.weapon

## Apakah kita sedang membidik memakai senjata yang punya gambar scope.
func _is_scoped() -> bool:
	if not is_aiming or _is_dead or _is_chatting:
		return false
	var w: WeaponResource = _current_weapon_resource()
	return w != null and w.has_scope

## Tampilkan/sembunyikan overlay scope sesuai kondisi bidik + senjata.
func _update_scope() -> void:
	if _scope_overlay == null:
		return
	_scope_overlay.visible = _is_scoped() and _is_local

## Sembunyikan viewmodel kalau ada dinding sangat dekat di depan kamera, supaya
## laras senjata tidak terlihat menembus/menonjol dari dinding. Saat membidik
## lewat scope, viewmodel juga disembunyikan (digantikan overlay scope).
func _update_weapon_occlusion() -> void:
	if not weapon_models or not main_camera:
		return
	var blocked: bool
	if _is_scoped():
		blocked = true
	else:
		var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
		var from: Vector3 = main_camera.global_position
		var to: Vector3 = from - main_camera.global_transform.basis.z * WEAPON_VIEWMODEL_RAY
		var query := PhysicsRayQueryParameters3D.create(from, to)
		query.collision_mask = 1  # layer World (dinding)
		query.exclude = [get_rid()]
		blocked = space.intersect_ray(query).is_empty() == false
	if blocked == _weapon_viewmodel_hidden:
		return
	_weapon_viewmodel_hidden = blocked
	weapon_models.visible = not blocked


func _physics_process(_delta: float) -> void:
	if _is_chatting:
		velocity.x = 0.0
		velocity.z = 0.0
		if not is_on_floor():
			velocity.y -= fall_gravity * _delta
		move_and_slide()
		return
	sprint_replenish(_delta)
	lean_collision()

	# Hitung ulang pengali kecepatan dari TOMBOL YANG SEDANG DITEKAN setiap frame
	# fisika, BUKAN dari event tekan/lepas. Kalau mengandalkan event saja, satu
	# event "lepas" yang hilang (pemain mati / buka chat / jendela kehilangan
	# fokus tepat saat tombol dilepas) membuat pemain nyangkut di mode sprint/
	# jalan selamanya. Sprint tetap tanpa batas (ala CoD).
	if not crouched:
		var sprint_on: bool = _sprint_latched if sprint_toggle else Input.is_action_pressed("sprint")
		if sprint_on:
			speed_modifier = sprint_speed
		elif Input.is_action_pressed("walk"):
			speed_modifier = walk_speed
		else:
			speed_modifier = NORMAL_speed

	if crouched and crouch_blocked:
		if !crouch_collision.is_colliding():
			crouch_blocked = false
			if !Input.is_action_pressed("crouch") and !crouch_toggle:
				crouch()
				
	# Gravitasi + pilih percepatan: di tanah pakai ground_acceleration, di udara
	# pakai air_acceleration (jauh lebih kecil supaya momentum lompatan terjaga).
	var _acceleration: float
	if not is_on_floor():
		_acceleration = air_acceleration
		
		if coyote_timer.is_stopped():
			coyote_timer.start(coyote_time)
	
		if velocity.y>0:
			velocity.y -= jump_gravity * _delta
		else:
			velocity.y -= fall_gravity * _delta
	else:
		_acceleration = ground_acceleration
		jump_available = true
		coyote_timer.stop()
		_speed = (base_speed / max((float(crouched)*crouch_speed_reduction),1)) * speed_modifier
		if jump_buffer:
			jump()
			jump_buffer = false
	# Handle Jump. Permintaan dicatat di _input (event-driven) supaya tepat satu
	# lompat per satu penekanan. JANGAN pakai Input.is_action_just_pressed di sini:
	# saat FPS < fisika, poll itu bisa menyala beberapa frame berturut-turut sehingga
	# satu penekanan memicu lompat berulang.
	if _jump_requested:
		_jump_requested = false
		if not _is_chatting:
			if jump_available:
				if crouched:
					crouch()
				else:
					lean(CENTRE)
					jump()
			else:
				jump_buffer = true
				get_tree().create_timer(jump_buffer_time).timeout.connect(on_jump_buffer_timeout)

	# Get the input direction and handle the movement/deceleration.
	# As good practice, you should replace UI actions with custom gameplay actions.
	var input_dir: Vector2 = Vector2.ZERO if _is_chatting else Input.get_vector("left", "right", "up", "down")
	var direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	# Percepatan vs perlambatan:
	# - ada input            -> percepatan (tanah: cepat, udara: kecil)
	# - tanpa input di tanah -> perlambatan supaya berhenti halus, tidak menyentak
	# - tanpa input di udara -> tidak diperlambat, momentum lompatan dipertahankan
	var accel_step: float = _acceleration * _delta
	if input_dir.is_zero_approx():
		accel_step = (ground_deceleration * _delta) if is_on_floor() else 0.0
	velocity.x = move_toward(velocity.x, direction.x * _speed, accel_step)
	velocity.z = move_toward(velocity.z, direction.z * _speed, accel_step)
	
	move_and_slide()

func jump()->void:
	velocity.y = jump_velocity
	jump_available = false

func _on_sprint_timer_timeout() -> void:
	sprint_on_cooldown = true
	get_tree().create_timer(sprint_cooldown_time).timeout.connect(_on_sprint_cooldown_timeout)
	speed_modifier = NORMAL_speed
	sprint_time_remaining = 0

func _on_death_timer_timeout() -> void:
	_respawn()

func _on_sprint_cooldown_timeout():
	sprint_on_cooldown = false

func _on_coyote_timer_timeout() -> void:
	jump_available = false

func on_jump_buffer_timeout()->void:
	jump_buffer = false

## Status bidik (RMB) dihitung dari tombol yang SEDANG ditekan tiap frame,
## supaya tidak bergantung pada event tekan/lepas yang bisa terlewat.
func _update_aim_state() -> void:
	var aiming_now: bool = Input.is_action_pressed("aim") and not _is_dead and not _is_chatting
	if aiming_now != is_aiming:
		is_aiming = aiming_now
		update_fov(_aim_fov_for_current_weapon() if is_aiming else default_fov)

## FOV saat membidik: pakai ZOOM milik senjata kalau diset (mis. `aim_zoom = 6.0`
## pada scope sniper -> FOV 75/6 = 12,5 derajat), kalau tidak pakai `aim_fov` biasa.
func _aim_fov_for_current_weapon() -> float:
	var w: WeaponResource = _current_weapon_resource()
	if w != null and w.aim_zoom > 0.0:
		return default_fov / w.aim_zoom
	return aim_fov

## Pengali sensitivitas mouse. Saat memakai scope ber-zoom tinggi gerakan mouse
## diperkecil supaya bidikan tetap terkendali (diatur per senjata).
func _scope_look_scale() -> float:
	var w: WeaponResource = _current_weapon_resource()
	if w == null or not w.has_scope or w.aim_zoom <= 0.0:
		return 1.0
	if not is_aiming or _is_dead or _is_chatting:
		return 1.0
	return clampf(w.zoom_sensitivity, 0.05, 1.0)

func update_fov(target_fov: float) -> void:
	# Hanya set TARGET; FOV benar-benar digeser tiap frame di _update_camera_feel
	# supaya aim & sprint berbagi satu jalur (tidak saling menimpa).
	_fov_target = target_fov

## Rasa kamera ala FPS modern (CoD / Combat Master / Blood Strike):
##  - FOV mengejar target (aim = zoom, sprint = sedikit lebih lebar),
##  - head-bob halus saat berjalan,
##  - kamera "turun" sedikit saat mendarat supaya terasa berbobot.
## Semua diterapkan pada MainCamera, yang TIDAK dianimasikan AnimationTree,
## jadi tidak bentrok dengan pose lean/crouch/air di LeanPivot.
func _update_camera_feel(delta: float) -> void:
	if main_camera == null:
		return
	var hspeed: float = Vector2(velocity.x, velocity.z).length()
	var on_floor: bool = is_on_floor()
	var speed_ratio: float = clampf(hspeed / maxf(move_speed, 0.01), 0.0, 1.6)

	# --- FOV: aim menimpa; sprint menambah sedikit supaya terasa kencang ---
	var want_fov: float = _fov_target
	if not is_aiming and on_floor and speed_modifier > 1.2 and hspeed > 1.0:
		want_fov += sprint_fov_kick
	main_camera.fov = lerp(main_camera.fov, want_fov, clampf(fov_lerp_speed * delta, 0.0, 1.0))

	# --- Landing dip: saat baru menyentuh tanah, turunkan kamera sesuai kecepatan jatuh ---
	if on_floor:
		if not _prev_on_floor:
			_land_dip = clampf((_fall_speed - 3.5) * landing_dip_scale, 0.0, landing_dip_max)
		_fall_speed = 0.0
	else:
		_fall_speed = maxf(_fall_speed, -velocity.y)
	_prev_on_floor = on_floor
	_land_dip = move_toward(_land_dip, 0.0, landing_dip_recover * delta)

	# --- Head-bob: hanya di tanah, hilang saat aim ---
	var target_amp: float = 0.0
	if on_floor and hspeed > 0.3 and not is_aiming:
		target_amp = bob_height * speed_ratio
	_bob_amp = lerp(_bob_amp, target_amp, clampf(10.0 * delta, 0.0, 1.0))
	if _bob_amp > 0.0001:
		_bob_phase += delta * bob_frequency * maxf(speed_ratio, 0.5)
	var bob_y: float = sin(_bob_phase * TAU) * _bob_amp
	var bob_x: float = sin(_bob_phase * TAU * 0.5) * _bob_amp * 0.6

	main_camera.position = Vector3(bob_x, bob_y - _land_dip, 0.0)
