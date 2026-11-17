extends RefCounted
class_name PlayerProfile

## Menyimpan & memuat nama pemain di penyimpanan lokal (user://).
## Dipakai oleh Main Menu (untuk menyimpan nama) dan World (untuk membacanya),
## sehingga nama bertahan walau scene berganti dan saat game dibuka lagi.

const CONFIG_PATH := "user://player_profile.cfg"
const DEFAULT_NAME := "Player"
const MAX_NAME_LENGTH := 16

## Ambil nama tersimpan; kembalikan "" kalau belum ada.
static func load_name() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return ""
	return sanitize(str(cfg.get_value("player", "name", "")))

## Simpan nama ke penyimpanan lokal.
static func save_name(player_name: String) -> void:
	var cfg := ConfigFile.new()
	# Muat dulu agar nilai lain (kalau ada) tidak hilang.
	cfg.load(CONFIG_PATH)
	cfg.set_value("player", "name", sanitize(player_name))
	cfg.save(CONFIG_PATH)

## Bersihkan nama: buang spasi berlebih, baris baru, dan batasi panjangnya.
static func sanitize(player_name: String) -> String:
	var n: String = player_name.strip_edges().replace("\n", " ").replace("\t", " ")
	n = n.substr(0, MAX_NAME_LENGTH)
	return n