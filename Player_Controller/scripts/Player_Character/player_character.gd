extends CharacterBody3D

@onready var camera: Node3D = %Camera
@onready var weapon_models: Node3D = $Camera/LeanPivot/MainCamera/Weapons_Manager/Weapons_Models

@export var subviewport_camera: Camera3D
@export var main_camera:Camera3D
@export var animation_tree: AnimationTree

#region Multiplayer Health
signal health_changed(health: float, max_health: float)

@export_category("Multiplayer Health")
@export var max_health: float = 100.0
var health: float = 100.0:
	set(value):
		health = clampf(value, 0.0, max_health)
		health_changed.emit(health, max_health)
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
var _death_time_remaining: float = 30.0  # detik sebelum respawn
var _death_timer_elapsed: float = 0.0  # elapsed time for countdown
var _original_collision_mask: int = 1  # untuk dipulihkan setelah respawn
var _death_position: Vector3 = Vector3.ZERO  # posisi saat mati (dipulihkan saat respawn)

var camera_rotation: Vector2 = Vector2(0.0,0.0)
var mouse_sensitivity = 0.001
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
@export var sprint_timer: Timer
@export var sprint_cooldown_time: float = 3.0
@export var sprint_time: float = 1.0
@export var sprint_replenish_rate: float = 0.30
@export var acceleration: float = 120
@export_range(0.01,1.0) var air_acceleration_modifier: float = 0.1
var sprint_on_cooldown: bool = false
var sprint_time_remaining: float = sprint_time
@onready var sprint_bar: Range = $CanvasLayer/SprintBar

const NORMAL_speed = 1
@export_range(1.0,3.0) var sprint_speed: float = 2.0
@export_range(0.1,1.0) var walk_speed: float = 0.5
var speed_modifier: float = NORMAL_speed

@export_category("Jump Parameters")
@export var coyote_timer: Timer
@export var jump_peak_time: float = .5
@export var jump_fall_time: float = .5
@export var jump_height: float = 2.0
@export var jump_distance: float = 4.0
@export var coyote_time: float = .1
@export var jump_buffer_time: float = .2

# Get the gravity from the project settings to be synced with RigidBody nodes.
var jump_gravity = ProjectSettings.get_setting("physics/3d/default_gravity")
var fall_gravity: float
var jump_velocity: float
var base_speed: float 
var _speed: float 
var jump_available: bool = true
var jump_buffer: bool = false

var _is_local: bool = true
var _weapon_viewmodel_hidden: bool = false
const WEAPON_VIEWMODEL_RAY := 0.9
const WEAPON_VISUAL_LAYER := 524288
const WORLD_VISUAL_LAYER := 1

func _ready() -> void:
	# HP: semua player masuk group "Target" supaya peluru bisa mengenainya.
	# "health" di-expose agar bisa disinkronkan ke semua client.
	health = max_health
	add_to_group("Target")
	GDSync.expose_var(self, "health")
	# Fungsi untuk memicu animasi tubuh (jongkok / miring) di client lain.
	GDSync.expose_func(_remote_set_blend)
	update_camera_rotation()
	calculate_movement_parameters()
	# Tentukan apakah instance ini milik client lokal (dikendalikan) atau milik
	# pemain lain (cuma ditampilkan). Owner bisa di-set sesaat setelah node ini
	# dibuat, jadi kita reaksikan juga perubahannya.
	GDSync.connect_gdsync_owner_changed(self, _on_gdsync_owner_changed)
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
		if weapon_models:
			# Tampilkan senjata lawan di layer dunia supaya terlihat "dipegang",
			# bukan melayang menembus dinding lewat overlay SubViewport.
			_set_viewmodel_layers(weapon_models, WORLD_VISUAL_LAYER)
			weapon_models.visible = true
	
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

func _respawn() -> void:
	# Set HP penuh; setter "health" yang akan memanggil _exit_death.
	health = max_health
	GDSync.sync_var(self, "health")

func update_camera_rotation() -> void:
	var current_rotation = get_rotation()
	camera_rotation.x = current_rotation.y
	camera_rotation.y = current_rotation.x
	
	
func _input(event: InputEvent) -> void:
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

	if event.is_action_pressed("aim"):
		is_aiming = true
		update_fov(aim_fov)
	if event.is_action_released("aim"):
		is_aiming = false
		update_fov(default_fov)
		
	if enable_sprint:
		if Input.is_action_just_pressed("sprint") and !crouched:
			if !sprint_on_cooldown:
				speed_modifier = sprint_speed
				sprint_timer.start(sprint_time_remaining)
				
		if Input.is_action_just_released("sprint") or Input.is_action_just_released("walk"):
			if !(Input.is_action_pressed("walk") or Input.is_action_pressed("sprint")):
				speed_modifier = NORMAL_speed
				exit_sprint()
				
		if Input.is_action_just_pressed("walk") and !crouched:
			speed_modifier = walk_speed
		if Input.is_action_just_pressed("walk") and !crouched:
			speed_modifier = walk_speed

func calculate_movement_parameters() -> void:
	jump_gravity = (2*jump_height)/pow(jump_peak_time,2)
	fall_gravity = (2*jump_height)/pow(jump_fall_time,2)
	jump_velocity = jump_gravity * jump_peak_time
	base_speed = jump_distance/(jump_peak_time+jump_fall_time)
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
	camera_rotation += Movement
	
	transform.basis = Basis()
	camera.transform.basis = Basis()
	
	rotate_object_local(Vector3(0,1,0),-camera_rotation.x) # first rotate in Y
	camera.rotate_object_local(Vector3(1,0,0), -camera_rotation.y) # then rotate in X
	camera_rotation.y = clamp(camera_rotation.y,-1.5,1.2)
	
func exit_sprint() -> void:
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

## Sembunyikan viewmodel kalau ada dinding sangat dekat di depan kamera, supaya
## laras senjata tidak terlihat menembus/menonjol dari dinding.
func _update_weapon_occlusion() -> void:
	if not weapon_models or not main_camera:
		return
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var from: Vector3 = main_camera.global_position
	var to: Vector3 = from - main_camera.global_transform.basis.z * WEAPON_VIEWMODEL_RAY
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 1  # layer World (dinding)
	query.exclude = [get_rid()]
	var blocked: bool = space.intersect_ray(query).is_empty() == false
	if blocked == _weapon_viewmodel_hidden:
		return
	_weapon_viewmodel_hidden = blocked
	weapon_models.visible = not blocked


func _physics_process(_delta: float) -> void:
	sprint_replenish(_delta)
	lean_collision()
	
	if crouched and crouch_blocked:
		if !crouch_collision.is_colliding():
			crouch_blocked = false
			if !Input.is_action_pressed("crouch") and !crouch_toggle:
				crouch()
				
	# Add the gravity.
	var _acceleration
	if not is_on_floor():
		_acceleration = acceleration*air_acceleration_modifier
		
		if coyote_timer.is_stopped():
			coyote_timer.start(coyote_time)
	
		if velocity.y>0:
			velocity.y -= jump_gravity * _delta
		else:
			velocity.y -= fall_gravity * _delta
	else:
		_acceleration = acceleration
		jump_available = true
		coyote_timer.stop()
		_speed = (base_speed / max((float(crouched)*crouch_speed_reduction),1)) * speed_modifier
		if jump_buffer:
			jump()
			jump_buffer = false
	# Handle Jump.
	if Input.is_action_just_pressed("ui_accept"):
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
	var input_dir = Input.get_vector("left", "right", "up", "down")
	var direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	velocity.x = move_toward(velocity.x, direction.x * _speed, _acceleration*_delta)
	velocity.z = move_toward(velocity.z, direction.z * _speed, _acceleration*_delta)
	
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

func update_fov(target_fov: float) -> void:
	var tween = get_tree().create_tween()
	tween.tween_property(main_camera, "fov", target_fov, 0.2)
