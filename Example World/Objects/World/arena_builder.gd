class_name ArenaBuilder
extends Node3D

## Arena FPS bergaya TACTICAL SHOOTER (Counter-Strike / Valorant), dibangun penuh
## dari KODE.
##
## Kenapa dari kode: aman dari scene di-save ulang, identik di semua client
## (tidak perlu disinkronkan), dan semua ukuran ada di _build() sehingga gampang
## diubah.
##
## KAMUS AREA (lihat juga denah di _build):
##   ARMORY   x 10..24, z  2..14   tempat spawn + rak senjata/amunisi
##   NE HALL  x 10..24, z -12..2   lorong timur, ada CATWALK 3 m di atasnya
##   MID      x -2..10, z -12..14  jalur tengah dari spawn
##   LONG     x -10..-2, z -16..14 jalur barat yang panjang
##   A SITE   x -10..-2, z -24..-16  site barat + tempat tinggi ("heaven")
##   CENTRE   x -2..14, z -24..-12   ruang penghubung (3 pintu + 1 bukaan)
##   B SITE   x 14..24, z -24..-12   site timur + tempat tinggi
##   RANGE    z 14..24             area terbuka belakang (galeri 30 target)
##
## Jalur & pintu (choke point):
##   ARMORY --pintu--> MID, ARMORY --pintu--> NE HALL, ARMORY --rampa--> CATWALK
##   CATWALK --> B SITE (turun), NE HALL --bukaan--> B SITE
##   MID --pintu--> CENTRE, MID --pintu--> LONG
##   LONG --celah--> A SITE, LONG --rampa--> A "heaven"
##   CENTRE --pintu--> A SITE, CENTRE --pintu--> B SITE
## Tiap site punya 2 jalan masuk, dan ada 3 tingkat ketinggian (3 / 1,8 / 3 m).

const FLOOR_Y := 1.38      # permukaan atas lantai (sama seperti map sebelumnya)
const WALL_H := 8.0        # tinggi dinding keliling
const TEX_PATH := "res://Example World/Models/Textures/prototype texture/Dark/texture_01.png"

var _mat: StandardMaterial3D

func _ready() -> void:
	_mat = StandardMaterial3D.new()
	_mat.albedo_texture = load(TEX_PATH)
	# Triplanar supaya tekstur tidak melar di balok panjang/pendek (sama seperti
	# material blok map lama `StandardMaterial3D_yv2ts`).
	_mat.uv1_triplanar = true
	_mat.uv1_scale = Vector3(0.3, 0.3, 0.3)

	var c := CSGCombiner3D.new()
	c.name = "ArenaGeometry"
	c.use_collision = true
	_build(c)
	# Dimasukkan ke tree SETELAH semua kotak disiapkan, supaya CSG dihitung sekali.
	add_child(c)

# ---------------------------------------------------------------------------
# Helper pembuat geometri
# ---------------------------------------------------------------------------

## Satu balok. (cx, cz) = titik tengah mendatar, top = permukaan ATAS.
func _box(c: CSGCombiner3D, cx: float, top: float, cz: float, sx: float, h: float, sz: float) -> void:
	var b := CSGBox3D.new()
	b.size = Vector3(sx, h, sz)
	b.material = _mat
	b.position = Vector3(cx, top - h * 0.5, cz)
	c.add_child(b)

## Balok yang dasarnya di lantai (tinggi sampai `top`).
func _solid(c: CSGCombiner3D, cx: float, top: float, cz: float, sx: float, sz: float) -> void:
	_box(c, cx, top, cz, sx, top - FLOOR_Y, sz)

## Rampa (bidang miring) - BUKAN anak tangga: CharacterBody3D Godot tidak bisa
## menaiki anak tangga (bidang tegak dianggap dinding). Rampa di sini ~29 derajat,
## di bawah floor_max_angle 45, jadi bisa ditanjaki jalan biasa.
## `low_z` = ujung bawah (di lantai), `high_z` = ujung atas (setinggi top_h).
func _ramp_z(c: CSGCombiner3D, cx: float, width: float, low_z: float, high_z: float, top_h: float) -> void:
	var run: float = absf(high_z - low_z)
	if run < 0.01:
		return
	var angle: float = atan2(top_h, run)
	var b := CSGBox3D.new()
	b.size = Vector3(width, 0.5, sqrt(run * run + top_h * top_h))
	b.material = _mat
	b.position = Vector3(cx, FLOOR_Y + top_h * 0.5 - 0.25 / cos(angle), (low_z + high_z) * 0.5)
	b.rotation.x = -signf(high_z - low_z) * angle
	c.add_child(b)

## Rampa yang naik sepanjang sumbu X.
func _ramp_x(c: CSGCombiner3D, cz: float, width: float, low_x: float, high_x: float, top_h: float) -> void:
	var run: float = absf(high_x - low_x)
	if run < 0.01:
		return
	var angle: float = atan2(top_h, run)
	var b := CSGBox3D.new()
	b.size = Vector3(sqrt(run * run + top_h * top_h), 0.5, width)
	b.material = _mat
	b.position = Vector3((low_x + high_x) * 0.5, FLOOR_Y + top_h * 0.5 - 0.25 / cos(angle), cz)
	b.rotation.z = signf(high_x - low_x) * angle
	c.add_child(b)

## Dinding tipis memanjang di sumbu X (pada z tertentu).
func _wall_x(c: CSGCombiner3D, z: float, x_from: float, x_to: float, thick: float = 0.5, h: float = 3.5) -> void:
	if absf(x_to - x_from) < 0.01:
		return
	_solid(c, (x_from + x_to) * 0.5, FLOOR_Y + h, z, absf(x_to - x_from) + thick, thick)

## Dinding tipis memanjang di sumbu Z (pada x tertentu).
func _wall_z(c: CSGCombiner3D, x: float, z_from: float, z_to: float, thick: float = 0.5, h: float = 3.5) -> void:
	if absf(z_to - z_from) < 0.01:
		return
	_solid(c, x, FLOOR_Y + h, (z_from + z_to) * 0.5, thick, absf(z_to - z_from) + thick)

## Dinding sumbu X dengan LUBANG PINTU di tengahnya (choke point).
func _wall_x_door(c: CSGCombiner3D, z: float, x_from: float, x_to: float, door: float, thick: float = 0.5, h: float = 3.5) -> void:
	var mid: float = (x_from + x_to) * 0.5
	_wall_x(c, z, x_from, mid - door * 0.5, thick, h)
	_wall_x(c, z, mid + door * 0.5, x_to, thick, h)

## Dinding sumbu Z dengan LUBANG PINTU di tengahnya (choke point).
func _wall_z_door(c: CSGCombiner3D, x: float, z_from: float, z_to: float, door: float, thick: float = 0.5, h: float = 3.5) -> void:
	var mid: float = (z_from + z_to) * 0.5
	_wall_z(c, x, z_from, mid - door * 0.5, thick, h)
	_wall_z(c, x, mid + door * 0.5, z_to, thick, h)

## Peti cover (1,6 m) - cukup untuk berlindung sambil berdiri.
func _crate(c: CSGCombiner3D, x: float, z: float) -> void:
	_box(c, x, FLOOR_Y + 1.6, z, 1.6, 1.6, 1.6)

## Tumpukan 2 peti (3,2 m) - cover tinggi, bisa dilompati dari peti lain.
func _crate_stack(c: CSGCombiner3D, x: float, z: float) -> void:
	_box(c, x, FLOOR_Y + 1.6, z, 1.6, 1.6, 1.6)
	_box(c, x + 0.3, FLOOR_Y + 3.2, z - 0.25, 1.4, 1.6, 1.4)

# ---------------------------------------------------------------------------
# Denah
# ---------------------------------------------------------------------------

func _build(c: CSGCombiner3D) -> void:
	# ======================= LANTAI & DINDING KELILING =======================
	_box(c, 7.0, FLOOR_Y, 0.0, 34.0, 1.0, 48.0)
	_box(c, -9.5, FLOOR_Y + WALL_H, 0.0, 1.0, WALL_H, 50.0)
	_box(c, 24.5, FLOOR_Y + WALL_H, 0.0, 1.0, WALL_H, 50.0)
	_box(c, 7.0, FLOOR_Y + WALL_H, -24.5, 36.0, WALL_H, 1.0)
	_box(c, 7.0, FLOOR_Y + WALL_H, 24.5, 36.0, WALL_H, 1.0)

	# ======================= DINDING PEMBAGI + PINTU =======================
	# x = 10 : ARMORY/N.E. HALL  <->  MID   (2 pintu, masing-masing 2 m)
	_wall_z_door(c, 10.0, 2.0, 14.0, 2.0)      # pintu ARMORY <-> MID
	_wall_z_door(c, 10.0, -12.0, 2.0, 2.0)     # pintu N.E. HALL <-> MID
	# z = 2 : ARMORY <-> N.E. HALL (pintu di depan spawn). Berhenti di x 20
	# supaya CATWALK (x 20..24) bisa lewat di atasnya.
	_wall_x_door(c, 2.0, 10.0, 20.0, 2.0)
	# z = -12 : MID <-> CENTRE (pintu), sisanya bukaan ke N.E. HALL
	_wall_x_door(c, -12.0, -2.0, 10.0, 2.0)
	# x = -2 : CENTRE <-> A SITE (pintu), lalu MID <-> LONG (pintu)
	_wall_z_door(c, -2.0, -24.0, -12.0, 2.0)
	_wall_z_door(c, -2.0, -12.0, 14.0, 2.0)
	# x = 14 : CENTRE <-> B SITE (pintu)
	_wall_z_door(c, 14.0, -24.0, -12.0, 2.0)
	# Choke tambahan: sisi timur LONG ditutup, sisa celah 3,5 m di barat
	_wall_x(c, -16.0, -6.5, -2.0)
	# Choke masuk B SITE dari N.E. HALL (sisa bukaan 3 m)
	_wall_x(c, -12.0, 14.0, 17.0)

	# ======================= ARMORY / SPAWN (x 10..24, z 2..14) =======================
	# Rak senjata & amunisi bawaan scene mengapung di sini; dibuatkan alasnya.
	_box(c, 18.5, FLOOR_Y + 0.34, 11.8, 9.5, 0.34, 1.6)
	_box(c, 15.8, FLOOR_Y + 1.17, 11.76, 2.6, 0.3, 0.9)
	_box(c, 20.35, FLOOR_Y + 0.92, 11.9, 5.8, 0.3, 0.9)
	_box(c, 12.0, FLOOR_Y + 0.9, 8.0, 0.6, 0.9, 5.0)          # cover pinggang
	_ramp_z(c, 22.0, 3.0, 8.0, 2.0, 3.0)                      # tangga ke CATWALK

	# ======================= N.E. HALL (x 10..24, z -12..2) =======================
	_solid(c, 22.0, FLOOR_Y + 3.0, -5.0, 4.0, 14.0)           # CATWALK 3 m
	_crate(c, 15.0, -6.0)
	_crate(c, 12.0, -2.0)
	_box(c, 16.0, FLOOR_Y + 0.9, -9.0, 6.0, 0.9, 0.6)

	# ======================= MID (x -2..10, z -12..14) =======================
	_crate(c, 2.0, 6.0)
	_crate_stack(c, 6.0, -2.0)
	_crate(c, 1.5, -6.0)
	_box(c, 6.0, FLOOR_Y + 2.6, 8.0, 1.2, 2.6, 1.2)           # pilar
	_box(c, 4.0, FLOOR_Y + 0.9, 0.0, 0.6, 0.9, 8.0)           # dinding rendah
	_box(c, 8.5, FLOOR_Y + 0.9, 4.0, 6.0, 0.9, 0.6)

	# ======================= LONG (x -10..-2, z -16..14) =======================
	_crate(c, -8.0, 6.0)
	_crate_stack(c, -4.5, 0.0)
	_crate(c, -7.0, -8.0)
	_crate(c, -4.0, -12.0)
	_box(c, -5.0, FLOOR_Y + 0.9, 10.0, 6.0, 0.9, 0.6)

	# ======================= A SITE (x -10..-2, z -24..-16) =======================
	_solid(c, -6.0, FLOOR_Y + 1.8, -20.0, 5.0, 6.0)           # kotak site (bombsite)
	_box(c, -3.0, FLOOR_Y + 0.9, -20.0, 1.0, 0.9, 2.0)        # anak tangga ke kotak
	_solid(c, -8.5, FLOOR_Y + 3.0, -22.0, 3.0, 4.0)           # "heaven" di dinding barat
	_ramp_z(c, -8.5, 3.0, -13.0, -20.0, 3.0)                  # rampa ke "heaven"
	_crate(c, -5.0, -17.5)
	_crate(c, -4.0, -22.5)

	# ======================= CENTRE (x -2..14, z -24..-12) =======================
	_crate(c, 4.0, -20.0)
	_crate_stack(c, 9.0, -16.0)
	_crate(c, 12.0, -22.0)
	_crate(c, 2.0, -14.0)
	_box(c, 7.0, FLOOR_Y + 0.9, -22.0, 6.0, 0.9, 0.6)
	_box(c, 6.0, FLOOR_Y + 2.6, -17.0, 1.2, 2.6, 1.2)         # pilar

	# ======================= B SITE (x 14..24, z -24..-12) =======================
	_solid(c, 17.0, FLOOR_Y + 1.8, -19.0, 5.0, 6.0)           # kotak site
	_box(c, 20.0, FLOOR_Y + 0.9, -19.0, 1.0, 0.9, 2.0)        # anak tangga
	_solid(c, 22.5, FLOOR_Y + 3.0, -21.5, 3.0, 5.0)           # tempat tinggi timur
	_ramp_z(c, 22.5, 3.0, -13.0, -19.0, 3.0)                  # rampa ke tempat tinggi
	_crate(c, 16.0, -13.5)
	_crate(c, 13.0, -17.0)