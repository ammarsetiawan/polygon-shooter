@icon("res://Player_Controller/scripts/Weapon_State_Machine/weapon_resource_icon.svg")
extends Resource

class_name WeaponResource

@warning_ignore("unused_signal")
signal update_overlay
@warning_ignore("unused_signal")
signal Zoom

@export_group("Weapon Animations")
##The Reference for the active weapons and pick ups
@export var weapon_name: String
## The Animation to play when the weapon was picked up
@export var pick_up_animation: String
## The Animation to play when the weapon is shot
@export var shoot_animation: String
## The Animation to play when the weapon reload
@export var reload_animation: String
## The Animation to play when the weapon is Changed
@export var change_animation: String
## The Animation to play when the weapon is dropped
@export var drop_animation: String
## The Animation to play when the weapon is out of ammo
@export var out_of_ammo_animation: String
## The Animation to play when you do the melee strike
@export var melee_animation: String

@export_group("Weapon Stats")
## If Uncheck Shoot Function Will skip ammo check
@export var has_ammo: bool = true
## The Maximum amount that you will reload if zero
@export var magazine: int
## The Maximum ammo that can be held in reserve.
@export var max_ammo: int
## The damage that a weapon will do
@export var damage: int
## The Melee damage that a weapon will do.
@export var melee_damage: float
## If Auto Fire is set to true the weapon will continuously fire until fire trigger is released
@export var auto_fire: bool
## The Range that a weapon will fire. Beyong this number no hit will trigger.
@export var fire_range: int
## Rate of fire dalam TEMBAKAN PER DETIK. Kalau diisi (>0) tempo tembakan senjata
## ini diatur ke nilai ini (dan dipakai untuk auto_fire). Kalau 0, tempo tetap
## mengikuti panjang animasi shoot seperti sebelumnya.
@export var fire_rate: float = 0.0

@export_group("Weapon Behaviour")
##If Checked the weapon drop scene MUST be provided
@export var can_be_dropped: bool
## The Rigid body to spawn for the weapon. It should be a Rigid Body of type Weapon_Pick_Up and have a matching weapon_name.
@export var weapon_drop: PackedScene
## The Spray_Profile to use when firing the weapon. It should be of Type Spray_Profile. This handles the spray calculations and passes back the information to the Projectile to load
@export var weapon_spray: PackedScene
## The Projectile that will be loaded. Not a Rigid body but class that handles the ray cast processing and can be either hitscan or rigid body. Should be of Type Projectile
@export var projectile_to_load: PackedScene
## Incremental Reload is for shotgun or sigle item loaded weapons where you can interupt the reload process. If true the Calculate_Reload function on the weapon_state_machine must be called indepently. 
## For Example: at each step of a shotgun reload the function is called via the animation player.
@export var incremental_reload: bool = false

@export_group("Recoil")
## Recoil vertikal (derajat) yang mendorong pandangan KE ATAS tiap tembakan.
@export var recoil_vertical: float = 0.35
## Simpangan recoil horizontal acak (derajat) tiap tembakan: +- nilai ini.
@export var recoil_horizontal: float = 0.18
## Jeda (detik) sebelum recoil mulai pulih setelah tembakan terakhir. Selama
## menembak terus-menerus jeda ini di-reset terus, sehingga pandangan naik (climb).
@export var recoil_recovery_delay: float = 0.12
## Kecepatan pemulihan recoil (derajat per detik).
@export var recoil_recovery_speed: float = 14.0
## Pengali recoil saat membidik (ADS). < 1 = lebih stabil.
@export var recoil_ads_multiplier: float = 0.7
## Pengali recoil saat jongkok.
@export var recoil_crouch_multiplier: float = 0.8

@export_group("Scope / Aim")
## Kalau true, saat pemain membidik (RMB) dengan senjata ini akan tampil overlay
## scope PROSEDURAL (digambar dari kode shader, tanpa tekstur PNG).
@export var has_scope: bool = false
## Perbesaran saat membidik (RMB), dalam KELIPATAN. 0 = pakai `aim_fov` pemain
## seperti biasa. Contoh 6.0 -> FOV jadi default_fov / 6 = 12,5 derajat
## (setara AWP di CS / Operator di Valorant).
@export var aim_zoom: float = 0.0
## Sensitivitas mouse saat zoom (1.0 = sama seperti tidak zoom). Untuk zoom besar
## nilai ini WAJIB dikecilkan supaya bidikan tidak terlalu sensitif.
@export var zoom_sensitivity: float = 1.0
