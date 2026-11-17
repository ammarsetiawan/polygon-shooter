shader_type canvas_item;
render_mode blend_mix, unshaded;

// =====================================================================
// Vignette MERAH di pinggir layar saat pemain terkena hit.
//   intensity = kekuatan merahnya (0..1)
//   spread    = seberapa jauh merah menjalar ke tengah layar (0..1)
// Dari GDScript, spread & intensity dinaikkan saat darah pemain berkurang,
// sehingga merahnya makin MELUAS ke tengah - dan dikedipkan sebentar tiap
// kali pemain kena tembakan.
// =====================================================================

uniform vec4  tint : source_color = vec4(0.75, 0.0, 0.0, 1.0);
uniform float intensity = 0.0;
uniform float spread = 0.0;

void fragment() {
	// q: 0 di tengah, 1 di pinggir layar (per sumbu).
	vec2 q = abs((UV - 0.5) * 2.0);
	// Jarak "superellipse" supaya merahnya mengikuti KEEMPAT pinggir layar
	// (kalau pakai length(), sudut layar jadi jauh lebih merah daripada pinggir).
	float d = pow(pow(q.x, 4.0) + pow(q.y, 4.0), 0.25);

	// spread 0 -> hanya di pinggir; spread 1 -> menjalar sampai tengah.
	float inner = clamp(1.0 - spread, 0.0, 0.98);
	float a = intensity * smoothstep(inner, 1.0, d);
	COLOR = vec4(tint.rgb, a * tint.a);
}