shader_type canvas_item;
render_mode blend_mix, unshaded;

// =====================================================================
// Scope bidik PROSEDURAL — digambar seluruhnya dari kode, TANPA tekstur PNG.
// Desain disamakan dengan scope-sniper.png:
//   1. latar DI LUAR lingkaran: hitam penuh (lensa di dalamnya tetap transparan)
//   2. cincin/bezel abu-abu lembut di tepi lingkaran
//   3. crosshair tipis dengan celah kecil di tengah
//   4. titik merah kecil di pusat
// (Pola kotak-kotak pada PNG lama adalah artefak dan TIDAK ditiru.)
// =====================================================================

// Ukuran layar dalam piksel (di-set dari GDScript saat resize).
uniform vec2  screen_size    = vec2(1920.0, 1080.0);
uniform float lens_radius    = 0.44;   // jari-jari lingkaran (fraksi sisi terpendek layar)
uniform float ring_thickness = 0.08;   // tebal cincin bezel (fraksi jari-jari)
uniform vec4  ring_color : source_color = vec4(0.55, 0.55, 0.57, 1.0);
uniform float ring_alpha     = 0.90;
uniform vec4  bg_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float bg_alpha       = 1.00;   // 1 = latar luar lensa hitam penuh
uniform float line_frac      = 0.0016; // setengah tebal garis crosshair (fraksi sisi terpendek)
uniform float line_start     = 0.08;   // awal garis dari pusat / celah tengah (fraksi jari-jari)
uniform float line_end       = 0.92;   // ujung garis (fraksi jari-jari)
uniform vec4  reticle_color : source_color = vec4(0.10, 0.10, 0.10, 1.0);
uniform float reticle_alpha  = 0.90;
uniform float dot_frac       = 0.0045; // jari-jari titik pusat (fraksi sisi terpendek)
uniform vec4  dot_color : source_color = vec4(0.85, 0.15, 0.15, 1.0);

// Gabungkan dua lapisan (src di atas dst) dengan alpha "over" biasa.
vec4 over(vec4 dst, vec4 src) {
	float a = src.a + dst.a * (1.0 - src.a);
	vec3 c = (src.rgb * src.a + dst.rgb * dst.a * (1.0 - src.a)) / max(a, 0.0001);
	return vec4(c, a);
}

void fragment() {
	float m = min(screen_size.x, screen_size.y);
	vec2  p = UV * screen_size - screen_size * 0.5;   // koordinat piksel dari pusat
	float r = length(p);
	float R = m * lens_radius;
	float aa = 1.0;                                    // lebar antialias (piksel)

	// --- 0) Latar DI LUAR lensa: hitam penuh (seperti vignette scope sungguhan).
	//         Lensa di dalam ring tetap transparan. ---
	float outside = smoothstep(R - aa, R + aa, r);

	// --- 1) Cincin bezel: pita lembut tepat di dalam tepi lingkaran ---
	float rw = R * ring_thickness;
	float rc = R - rw * 0.5;
	float ring = 1.0 - smoothstep(0.0, rw * 0.85, abs(r - rc));

	// --- 2) Crosshair: garis tipis dengan celah kecil di pusat ---
	float line = m * line_frac;
	float arm = smoothstep(R * line_start - aa, R * line_start + aa, r)
			  * (1.0 - smoothstep(R * line_end - aa, R * line_end + aa, r));
	float cross = max(1.0 - smoothstep(line - aa, line + aa, abs(p.y)),
					  1.0 - smoothstep(line - aa, line + aa, abs(p.x))) * arm;

	// --- 3) Titik merah kecil di pusat ---
	float dr = m * dot_frac;
	float dot = 1.0 - smoothstep(dr - aa, dr + aa, r);

	vec4 c = vec4(0.0);
	c = over(c, vec4(bg_color.rgb,      outside * bg_alpha));
	c = over(c, vec4(ring_color.rgb,    ring * ring_alpha));
	c = over(c, vec4(reticle_color.rgb, cross * reticle_alpha));
	c = over(c, vec4(dot_color.rgb,     dot));
	COLOR = c;
}