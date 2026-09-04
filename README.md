# avdl_dashboard

Prototipe APK satu layar untuk penelitian AVDL: menampilkan interval uji dari
`backend/phase5_test_labeled.csv` dan meminta prediksi kepadatan (low / medium /
high) dari Random Forest lewat `backend/main.py`.

Seluruh logika ada di `lib/main.dart`.

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
| "Ditolak (401): API key aplikasi tidak sama…" | nilai define ≠ env var `API_KEY` di backend |
| "Backend belum siap (503)…" | `API_KEY` belum diset di backend, atau artefak model gagal dimuat |
| "Tidak bisa menghubungi backend di …" | backend mati, beda Wi-Fi, atau `BASE_URL` salah |
| Banner memuat "server: API_KEY belum diset" | `GET /health` melaporkan backend belum dikonfigurasi |

`GET /health` sengaja tidak butuh API key, jadi banner status tetap informatif
walau kunci salah.

## Catatan

`test/widget_test.dart` masih template Flutter bawaan dan menunjuk kelas `MyApp`
yang tidak ada di proyek ini (kelas sebenarnya `AvdlApp`), sehingga
`flutter analyze` melaporkan satu error di file itu. Tidak memengaruhi APK.
