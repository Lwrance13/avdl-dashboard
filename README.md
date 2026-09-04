# avdl_dashboard

Prototipe APK untuk penelitian AVDL: membaca interval uji dari
`backend/phase5_test_labeled.csv` dan meminta prediksi kepadatan (low / medium /
high) dari Random Forest lewat `backend/main.py`.

Empat tab, seluruhnya di `lib/main.dart`:

| Tab | Isi | Endpoint |
|-----|-----|----------|
| **Prediksi** | Daftar interval uji; ketuk satu baris untuk memprediksi kelas interval berikutnya, lengkap dengan tiga probabilitas | `/samples`, `/predict` |
| **Jumlah** | Total per kelas kendaraan, plus perbandingan antar lokasi kamera | `/stats/counts` |
| **Tren** | Jumlah per kelas terhadap waktu untuk satu lokasi | `/stats/trend` |
| **SHAP** | Lima fitur teratas dan pembagian sinyal-lalin vs bookkeeping | `/shap/top-features` |

Filter lokasi ada satu, di atas semua tab. Tab Tren tidak menerima "Semua lokasi"
karena `/stats/trend` mewajibkan satu lokasi konkret.

## Catatan tentang isi grafik

- **Angkanya adalah split uji, bukan seluruh dataset.** Sumbernya 314 interval di
  5 lokasi (Gaitenis tidak punya episode valid). Jangan sebut sebagai statistik
  keseluruhan dataset.
- **Tab Jumlah dan Tren memakai small multiples**, satu panel per kelas dengan
  skala sendiri — bukan satu grafik berisi enam seri. Alasannya bentuk datanya:
  Vehicles 3.417 sementara Scooters 1, jadi enam seri pada satu sumbu akan
  membuat lima di antaranya tak terlihat.
- **Garis tren sengaja terputus di batas episode.** Rekaman AVDL terputus-putus;
  satu lokasi bisa memuat beberapa episode berjarak berjam-jam. Menyambungnya
  akan menyiratkan kontinuitas yang tidak ada.
- **Kelas kepadatan memakai ramp biru satu warna** (low terang → high gelap; di
  mode gelap terbalik, makin padat makin terang), bukan hijau/kuning/merah.
  Alasannya terukur: pada skema lampu-lalin hijau vs kuning hanya berjarak CVD
  ΔE 3,0 di protanopia terhadap ambang 8, sehingga pembaca buta warna
  merah-hijau tidak bisa memisahkan low dari medium. Nama kelasnya selalu
  ditulis di sebelah warnanya.
- Karena itu **benar/salah ditandai ikon + teks**, bukan hijau/merah — supaya
  tidak ada dua sistem warna yang bersaing di satu layar.
- Setiap grafik punya **kembaran tabel** di tombol kanan-atas kartu, jadi tidak
  ada nilai yang hanya bisa dibaca lewat warna atau sentuhan.

## Prasyarat

Backend harus jalan lebih dulu dan `API_KEY` sudah diset di sana:

```bash
cd ../backend
API_KEY=<kunci> .venv/Scripts/python.exe -m uvicorn main:app --host 0.0.0.0 --port 8000
```

`--host 0.0.0.0` wajib kalau diuji di HP fisik — `127.0.0.1` hanya bisa diakses
dari laptop itu sendiri. HP dan laptop harus satu jaringan Wi-Fi.

## Menjalankan

API key TIDAK disimpan di source code. Nilainya disuntikkan saat build dengan
`--dart-define` dan harus sama dengan env var `API_KEY` di backend.

```bash
# di HP fisik yang terhubung lewat USB
flutter run --dart-define=API_KEY=<kunci>

# APK debug (yang dipakai untuk pengujian di Infinix X698)
flutter build apk --debug --dart-define=API_KEY=<kunci>
# hasil: build/app/outputs/flutter-apk/app-debug.apk

# alamat backend selain default (default http://192.168.1.6:8000)
flutter run --dart-define=API_KEY=<kunci> --dart-define=BASE_URL=http://192.168.1.10:8000
```

| Define | Wajib | Default |
|--------|-------|---------|
| `API_KEY` | ya | kosong → semua endpoint data menjawab 401 |
| `BASE_URL` | tidak | `http://192.168.1.6:8000` |

Cek IP LAN laptop dengan `ipconfig` (cari IPv4 pada adapter Wi-Fi). Kalau IP-nya
berubah, cukup ganti `--dart-define=BASE_URL=...`, tidak perlu mengedit Dart.

Batas pengamanan: kunci di dalam APK bisa diekstrak siapa pun yang memegang file
APK-nya. `--dart-define` menjauhkan kunci dari source code dan git, bukan dari
pembongkaran APK. Memadai untuk prototipe penelitian di LAN, bukan pengganti
autentikasi per pengguna.

## Dua API key: admin dan reviewer

Backend menerima **dua kunci** yang sama-sama sah di header `X-API-Key`:

| Kunci | Env var di backend | Rate limit |
|-------|--------------------|------------|
| Admin | `API_KEY` | tidak ada |
| Reviewer | `REVIEWER_API_KEY` | hanya `POST /predict`, `REVIEWER_RATE_LIMIT` per 60 detik (default 60) |

Keduanya punya akses yang sama ke seluruh endpoint. Tidak ada endpoint yang
mengubah data, jadi "read-only" di sini bukan berarti kemampuannya lebih sedikit —
gunanya supaya kunci reviewer bisa dibagikan, lalu dicabut, tanpa menyentuh kunci
yang dipakai APK utama.

**Aplikasi tidak perlu diubah sama sekali.** `lib/main.dart` hanya mengirim nilai
`--dart-define=API_KEY` apa pun isinya; yang menentukan perannya adalah nilai mana
yang cocok di sisi server. Jadi APK untuk reviewer dibangun dengan perintah yang
sama, cukup ganti nilainya:

```bash
flutter build apk --release \
  --dart-define=API_KEY=<kunci-reviewer> \
  --dart-define=BASE_URL=https://avdl-backend-production.up.railway.app
# hasil: build/app/outputs/flutter-apk/app-release.apk
```

`BASE_URL` **wajib** diisi di sini, karena defaultnya masih alamat LAN lama
(`http://192.168.1.6:8000`) yang tidak bisa dijangkau reviewer.

Untuk memastikan servernya sudah dikonfigurasi sebelum membangun APK, cukup buka
`/health` — endpoint itu tidak butuh kunci dan melaporkan `reviewer_key_configured`
serta `reviewer_rate_limit_per_min`:

```bash
curl -s https://avdl-backend-production.up.railway.app/health
```

Kalau `reviewer_key_configured` masih `false`, `REVIEWER_API_KEY` belum diset di
dashboard hosting dan kunci reviewer akan ditolak 401.

Kalau batas laju terlampaui, backend menjawab **429** beserta header `Retry-After`
dan aplikasi menampilkan "Dibatasi lajunya (429)…" — bukan error jaringan. Kunci
admin tidak pernah dibatasi, jadi pengujian dengan kunci admin tidak akan pernah
memunculkan pesan itu.

## Konfigurasi Android yang sudah terpasang

`android/app/src/main/AndroidManifest.xml` sudah memuat keduanya — jangan dihapus:

- `<uses-permission android:name="android.permission.INTERNET"/>` (baris 2)
- `android:usesCleartextTraffic="true"` pada `<application>` (baris 7), karena
  backend LAN memakai HTTP polos dan Android 9+ memblokirnya secara default.
  Setelah backend pindah ke HTTPS, atribut ini bisa dihapus.

## Kalau layar data kosong

| Yang terlihat | Penyebab |
|---------------|----------|
| Banner "API key belum disuntikkan" | build tanpa `--dart-define=API_KEY` |
| "Ditolak (401): API key aplikasi tidak sama…" | nilai define tidak cocok dengan `API_KEY` maupun `REVIEWER_API_KEY` di backend |
| "Dibatasi lajunya (429)…" | kunci reviewer melewati batas `POST /predict`; tunggu lalu coba lagi |
| "Backend belum siap (503)…" | `API_KEY` **dan** `REVIEWER_API_KEY` sama-sama belum diset di backend, atau artefak model gagal dimuat |
| "Tidak bisa menghubungi backend di …" | backend mati, beda Wi-Fi, atau `BASE_URL` salah |
| Banner memuat "server: API_KEY belum diset" | `GET /health` melaporkan backend belum dikonfigurasi |

`GET /health` sengaja tidak butuh API key, jadi banner status tetap informatif
walau kunci salah.

## Catatan

`test/widget_test.dart` masih template Flutter bawaan dan menunjuk kelas `MyApp`
yang tidak ada di proyek ini (kelas sebenarnya `AvdlApp`), sehingga
`flutter analyze` melaporkan satu error di file itu. Tidak memengaruhi APK.
