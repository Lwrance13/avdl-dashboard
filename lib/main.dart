// AVDL Dashboard — prototipe APK satu layar untuk penelitian.
//
// Membutuhkan paket `http` di pubspec.yaml:  http: ^1.4.0
//
// LANGKAH TERPISAH (bukan di file ini) — android/app/src/main/AndroidManifest.xml:
//   1. <uses-permission android:name="android.permission.INTERNET"/>
//      di dalam <manifest>, di luar <application>
//   2. android:usesCleartextTraffic="true" pada tag <application>,
//      karena Android 9+ memblokir HTTP polos dan backend ini bukan HTTPS.
// Tanpa keduanya, semua permintaan gagal meski backend berjalan normal.
//
// Nama field mengikuti backend/main.py yang sebenarnya:
//   GET /samples  memakai query `limit` & `offset` (BUKAN page/page_size)
//                 dan mengembalikan {total, count, samples:[{id, location,
//                 interval_start, true_label}]}
//   Field `timestamp`/`interval_start` dan `density_label`/`true_label`
//   dibaca dua-duanya supaya aman kalau penamaannya berubah.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

// ---------------------------------------------------------------------------
// Konfigurasi
// ---------------------------------------------------------------------------
//
// API key disuntikkan saat build lewat --dart-define, TIDAK ditulis di file ini
// supaya tidak ikut masuk repo:
//
//   flutter run       --dart-define=API_KEY=<kunci>
//   flutter build apk --release --dart-define=API_KEY=<kunci>
//
// Nilainya harus sama dengan env var API_KEY di backend.
//
// String.fromEnvironment hanya dievaluasi pada const context — jangan ubah
// `const` di bawah menjadi `final`, nilainya akan selalu kosong.
//
// BATAS PENGAMANAN: kunci di dalam APK tetap bisa diekstrak oleh siapa pun yang
// memegang file APK-nya. --dart-define menjauhkan kunci dari source code dan
// git, bukan dari pembongkaran APK. Memadai untuk prototipe penelitian di LAN,
// bukan pengganti autentikasi per pengguna.

/// Dikirim sebagai header `X-API-Key`. Wajib untuk semua endpoint backend
/// kecuali `GET /health`. Kosong berarti build tanpa --dart-define=API_KEY.
const String kApiKey = String.fromEnvironment('API_KEY');

/// Alamat backend; bisa diganti tanpa mengubah file ini:
///   --dart-define=BASE_URL=http://192.168.1.10:8000
/// Default = IP LAN laptop untuk pengujian di HP fisik (cek `ipconfig`; HP dan
/// laptop satu Wi-Fi, backend dijalankan dengan --host 0.0.0.0).
/// Emulator Android: 'http://10.0.2.2:8000'. iOS Simulator: 'http://127.0.0.1:8000'.
const String kBaseUrl = String.fromEnvironment(
  'BASE_URL',
  defaultValue: 'http://192.168.1.6:8000',
);

const Duration kTimeout = Duration(seconds: 8);
const int kPageSize = 50;
const String kAllLocations = 'All';

/// Header untuk setiap GET. Backend mengabaikannya di /health.
const Map<String, String> kGetHeaders = <String, String>{'X-API-Key': kApiKey};

/// Header untuk POST /predict.
const Map<String, String> kJsonHeaders = <String, String>{
  'Content-Type': 'application/json',
  'X-API-Key': kApiKey,
};

void main() => runApp(const AvdlApp());

class AvdlApp extends StatelessWidget {
  const AvdlApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AVDL Dashboard',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3B6EA5)),
      ),
      home: const DashboardPage(),
    );
  }
}

// ---------------------------------------------------------------------------
// MODEL DATA — hanya yang dipakai layar ini
// ---------------------------------------------------------------------------

/// Satu baris daftar sample.
class Sample {
  const Sample({
    required this.id,
    required this.location,
    required this.timestamp,
    required this.trueLabel,
  });

  final int id;
  final String location;
  final String timestamp;
  final String? trueLabel;

  /// Menerima `interval_start` maupun `timestamp`, dan `true_label` maupun
  /// `density_label`, supaya tidak pecah kalau nama field berbeda.
  factory Sample.fromJson(Map<String, dynamic> json) {
    final Object? time = json['interval_start'] ?? json['timestamp'];
    final Object? label = json['true_label'] ?? json['density_label'];
    return Sample(
      id: (json['id'] as num?)?.toInt() ?? -1,
      location: (json['location'] ?? '-').toString(),
      timestamp: time?.toString() ?? '',
      trueLabel: label?.toString(),
    );
  }
}

/// Hasil POST /predict.
class Prediction {
  const Prediction({
    required this.predictedLabel,
    required this.probabilities,
    required this.trueLabel,
  });

  final String predictedLabel;
  final Map<String, double> probabilities;
  final String? trueLabel;

  factory Prediction.fromJson(Map<String, dynamic> json) {
    final Map<String, double> probs = <String, double>{};
    final Object? raw = json['probabilities'];
    if (raw is Map) {
      raw.forEach((Object? key, Object? value) {
        if (value is num) probs[key.toString()] = value.toDouble();
      });
    }
    final Object? label = json['true_label'] ?? json['density_label'];
    return Prediction(
      predictedLabel: (json['predicted_label'] ?? '?').toString(),
      probabilities: probs,
      trueLabel: label?.toString(),
    );
  }

  /// Benar hanya kalau kedua label ada dan sama. Null = tidak bisa dinilai.
  bool? get isCorrect {
    if (trueLabel == null || trueLabel!.isEmpty) return null;
    return trueLabel!.toLowerCase() == predictedLabel.toLowerCase();
  }
}

/// Ringkasan GET /health.
class Health {
  const Health({required this.modelLoaded, required this.detail});

  final bool modelLoaded;
  final String detail;

  factory Health.fromJson(Map<String, dynamic> json) {
    final Object? error = json['load_error'];
    final List<String> bits = <String>[];
    if (json['n_samples'] != null) bits.add('${json['n_samples']} sample');
    if (json['n_features'] != null) bits.add('${json['n_features']} fitur');
    if (json['sklearn_version'] != null) {
      bits.add('sklearn ${json['sklearn_version']}');
    }
    if (json['scaler_loaded_but_unused'] == true) bits.add('scaler tidak dipakai');
    // Field baru dari backend: server tanpa API_KEY akan menolak semua endpoint
    // data dengan 503 walaupun /health sendiri menjawab 200.
    if (json['api_key_configured'] == false) bits.add('server: API_KEY belum diset');
    if (error != null) bits.add('load_error: $error');
    return Health(modelLoaded: json['model_loaded'] == true, detail: bits.join(' · '));
  }
}

// ---------------------------------------------------------------------------
// PANGGILAN API — semua dibungkus try/catch di pemanggilnya
// ---------------------------------------------------------------------------

class ApiException implements Exception {
  ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

String _friendlyError(Object error) {
  final String host = kBaseUrl.replaceFirst(RegExp(r'^https?://'), '');
  if (error is TimeoutException) {
    return 'Backend $host tidak menjawab dalam ${kTimeout.inSeconds} detik.';
  }
  return 'Tidak bisa menghubungi backend di $host. Apakah sudah dijalankan?';
}

/// Pesan untuk status non-200. 401, 429 dan 503 dipisahkan karena ketiganya
/// hampir selalu soal konfigurasi kunci atau batas laju, bukan soal jaringan —
/// tanpa ini pengguna hanya melihat "HTTP 401" dan menduga backend mati.
String _httpErrorMessage(int statusCode, String path) {
  if (statusCode == 401) {
    return kApiKey.isEmpty
        ? 'Ditolak (401): aplikasi dibuild tanpa --dart-define=API_KEY.'
        : 'Ditolak (401): API key aplikasi tidak sama dengan env var API_KEY di server.';
  }
  if (statusCode == 429) {
    return 'Dibatasi lajunya (429): permintaan terlalu sering untuk API key ini. '
        'Tunggu sebentar lalu coba lagi.';
  }
  if (statusCode == 503) {
    return 'Backend belum siap (503): env var API_KEY belum diset di server, atau '
        'artefak model gagal dimuat. Cek GET /health.';
  }
  return 'HTTP $statusCode dari $path';
}

Future<Object?> _getJson(String path) async {
  try {
    final http.Response res = await http
        .get(Uri.parse('$kBaseUrl$path'), headers: kGetHeaders)
        .timeout(kTimeout);
    if (res.statusCode != 200) {
      throw ApiException(_httpErrorMessage(res.statusCode, path));
    }
    return jsonDecode(res.body);
  } on ApiException {
    rethrow;
  } catch (error) {
    throw ApiException(_friendlyError(error));
  }
}

Future<Health> fetchHealth() async {
  final Object? json = await _getJson('/health');
  if (json is Map<String, dynamic>) return Health.fromJson(json);
  throw ApiException('Balasan /health tidak dikenali.');
}

Future<List<String>> fetchLocations() async {
  final Object? json = await _getJson('/locations');
  final List<String> out = <String>[];
  if (json is List) {
    for (final Object? item in json) {
      out.add(item.toString());
    }
  }
  out.sort();
  return out;
}

/// Backend memakai `limit` & `offset`; tidak ada `page`/`page_size` di sana.
Future<List<Sample>> fetchSamples({String? location}) async {
  final StringBuffer path = StringBuffer('/samples?limit=$kPageSize&offset=0');
  if (location != null && location != kAllLocations) {
    path.write('&location=${Uri.encodeQueryComponent(location)}');
  }
  final Object? json = await _getJson(path.toString());
  final List<Sample> out = <Sample>[];
  final Object? list = json is Map<String, dynamic> ? json['samples'] : json;
  if (list is List) {
    for (final Object? item in list) {
      if (item is Map<String, dynamic>) out.add(Sample.fromJson(item));
    }
  }
  return out;
}

Future<Prediction> postPredict(int sampleId) async {
  try {
    final http.Response res = await http
        .post(
          Uri.parse('$kBaseUrl/predict'),
          headers: kJsonHeaders,
          body: jsonEncode(<String, dynamic>{'sample_id': sampleId}),
        )
        .timeout(kTimeout);
    if (res.statusCode != 200) {
      throw ApiException('Prediksi gagal — ${_httpErrorMessage(res.statusCode, '/predict')}');
    }
    final Object? json = jsonDecode(res.body);
    if (json is! Map<String, dynamic>) {
      throw ApiException('Balasan /predict bukan objek JSON.');
    }
    return Prediction.fromJson(json);
  } on ApiException {
    rethrow;
  } catch (error) {
    throw ApiException(_friendlyError(error));
  }
}

/// Warna kelas: hijau / oranye / merah.
Color densityColor(String? label) {
  switch ((label ?? '').toLowerCase()) {
    case 'low':
      return const Color(0xFF2E7D32);
    case 'medium':
      return const Color(0xFFEF6C00);
    case 'high':
      return const Color(0xFFC62828);
    default:
      return const Color(0xFF757575);
  }
}

/// "2026-09-02T14:15:00" -> "02 Sep 2026 14:15"; kalau gagal, teks asli.
String formatTimestamp(String raw) {
  if (raw.isEmpty) return '-';
  final DateTime? dt = DateTime.tryParse(raw);
  if (dt == null) return raw;
  const List<String> months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'Mei',
    'Jun',
    'Jul',
    'Agu',
    'Sep',
    'Okt',
    'Nov',
    'Des',
  ];
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(dt.day)} ${months[dt.month - 1]} ${dt.year} '
      '${two(dt.hour)}:${two(dt.minute)}';
}

// ---------------------------------------------------------------------------
// LAYAR — state + build
// ---------------------------------------------------------------------------

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  // --- STATE ---------------------------------------------------------------
  bool _backendOk = true; // false -> banner peringatan, UI tetap jalan
  String _healthDetail = '';

  List<String> _locations = <String>[];
  String _selected = kAllLocations;

  List<Sample> _samples = <Sample>[];
  bool _loadingSamples = true;
  String? _listError;

  int? _predictingId; // spinner pada baris yang sedang diprediksi
  int? _expandedId; // baris yang menampilkan kartu hasil
  final Map<int, Prediction> _results = <int, Prediction>{};

  @override
  void initState() {
    super.initState();
    _checkHealth(); // senyap, tidak memblokir
    _loadLocations();
    _loadSamples();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // --- PANGGILAN API -------------------------------------------------------

  /// Health check senyap: hanya mengatur banner, tidak memunculkan SnackBar.
  Future<void> _checkHealth() async {
    try {
      final Health health = await fetchHealth();
      if (!mounted) return;
      setState(() {
        // /health tetap 200 tanpa API key, tapi kalau kunci tidak ikut dibuild
        // semua endpoint data akan 401 — tandai sebagai tidak siap supaya
        // banner muncul, bukan membiarkan pengguna menebak.
        _backendOk = health.modelLoaded && kApiKey.isNotEmpty;
        _healthDetail = kApiKey.isEmpty
            ? 'Build tanpa --dart-define=API_KEY. ${health.detail}'
            : health.detail;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _backendOk = false;
        _healthDetail = error.toString();
      });
    }
  }

  Future<void> _loadLocations() async {
    try {
      final List<String> locations = await fetchLocations();
      if (!mounted) return;
      setState(() {
        _locations = locations;
        if (_selected != kAllLocations && !locations.contains(_selected)) {
          _selected = kAllLocations;
        }
      });
    } catch (error) {
      _snack('Gagal memuat daftar lokasi: $error');
    }
  }

  Future<void> _loadSamples() async {
    setState(() {
      _loadingSamples = true;
      _listError = null;
    });
    try {
      final List<Sample> samples = await fetchSamples(location: _selected);
      if (!mounted) return;
      setState(() {
        _samples = samples;
        _loadingSamples = false;
        _expandedId = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingSamples = false;
        _listError = error.toString();
      });
      _snack('Gagal memuat sample: $error');
    }
  }

  Future<void> _predict(Sample sample) async {
    setState(() => _predictingId = sample.id);
    try {
      final Prediction result = await postPredict(sample.id);
      if (!mounted) return;
      setState(() {
        _results[sample.id] = result;
        _predictingId = null;
        _expandedId = sample.id;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _predictingId = null);
      _snack('Prediksi gagal: $error');
    }
  }

  // --- BUILD ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AVDL Dashboard'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Muat ulang',
            onPressed: _loadingSamples
                ? null
                : () {
                    _checkHealth();
                    _loadLocations();
                    _loadSamples();
                  },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (!_backendOk) _buildWarningBanner(),
          _buildLocationDropdown(),
          const Divider(height: 1),
          Expanded(child: _buildSampleList()),
        ],
      ),
    );
  }

  /// Banner permanen saat health gagal. UI lain tetap bisa dipakai.
  Widget _buildWarningBanner() {
    return Material(
      color: const Color(0xFFFFF3E0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Row(
          children: <Widget>[
            const Icon(Icons.warning_amber_rounded, color: Color(0xFFEF6C00)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    kApiKey.isEmpty ? 'API key belum disuntikkan' : 'Backend not reachable',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    _healthDetail.isEmpty ? kBaseUrl : '$kBaseUrl — $_healthDetail',
                    style: const TextStyle(fontSize: 11),
                  ),
                ],
              ),
            ),
            TextButton(onPressed: _checkHealth, child: const Text('Cek')),
          ],
        ),
      ),
    );
  }

  Widget _buildLocationDropdown() {
    final List<String> items = <String>[kAllLocations, ..._locations];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: DropdownButtonFormField<String>(
        initialValue: items.contains(_selected) ? _selected : kAllLocations,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Lokasi kamera',
          border: OutlineInputBorder(),
          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
        items: items
            .map(
              (String value) => DropdownMenuItem<String>(
                value: value,
                child: Text(value, overflow: TextOverflow.ellipsis),
              ),
            )
            .toList(),
        onChanged: _loadingSamples
            ? null
            : (String? value) {
                if (value == null || value == _selected) return;
                setState(() => _selected = value);
                _loadSamples();
              },
      ),
    );
  }

  Widget _buildSampleList() {
    if (_loadingSamples) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_listError != null && _samples.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const Icon(Icons.cloud_off, size: 48, color: Color(0xFFC62828)),
              const SizedBox(height: 10),
              Text(_listError!, textAlign: TextAlign.center),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _loadSamples,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    if (_samples.isEmpty) {
      return const Center(child: Text('Tidak ada sample untuk filter ini.'));
    }
    return RefreshIndicator(
      onRefresh: _loadSamples,
      child: ListView.separated(
        itemCount: _samples.length,
        separatorBuilder: (BuildContext _, int _) => const Divider(height: 1),
        itemBuilder: (BuildContext context, int index) => _buildSampleRow(_samples[index]),
      ),
    );
  }

  /// Satu baris + kartu hasil yang muncul di bawahnya saat ditekan.
  Widget _buildSampleRow(Sample sample) {
    final bool busy = _predictingId == sample.id;
    final bool expanded = _expandedId == sample.id;
    final Prediction? result = _results[sample.id];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ListTile(
          leading: CircleAvatar(
            radius: 17,
            backgroundColor: densityColor(sample.trueLabel).withValues(alpha: 0.15),
            child: Text(
              '${sample.id}',
              style: TextStyle(fontSize: 11, color: densityColor(sample.trueLabel)),
            ),
          ),
          title: Text(sample.location, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(formatTimestamp(sample.timestamp)),
          trailing: busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(expanded ? Icons.expand_less : Icons.chevron_right, color: Colors.grey),
          onTap: _predictingId != null
              ? null
              : () {
                  if (expanded) {
                    setState(() => _expandedId = null);
                  } else if (result != null) {
                    setState(() => _expandedId = sample.id);
                  } else {
                    _predict(sample);
                  }
                },
        ),
        if (expanded && result != null) _buildResultCard(result),
      ],
    );
  }

  /// Kartu hasil: label prediksi, tiga bar probabilitas, label sebenarnya.
  Widget _buildResultCard(Prediction result) {
    final Color color = densityColor(result.predictedLabel);
    final bool? correct = result.isCorrect;
    return Container(
      color: const Color(0xFFF7F7F7),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      result.predictedLabel.toUpperCase(),
                      style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: color),
                    ),
                    Text(
                      'label sebenarnya: '
                      '${(result.trueLabel ?? "-").toUpperCase()}',
                    ),
                  ],
                ),
              ),
              if (correct != null)
                Row(
                  children: <Widget>[
                    Icon(
                      correct ? Icons.check_circle : Icons.cancel,
                      color: correct ? const Color(0xFF2E7D32) : const Color(0xFFC62828),
                      size: 30,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      correct ? 'Correct' : 'Incorrect',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: correct ? const Color(0xFF2E7D32) : const Color(0xFFC62828),
                      ),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 10),
          ..._orderedProbs(
            result,
          ).map((MapEntry<String, double> e) => _probabilityBar(e.key, e.value)),
        ],
      ),
    );
  }

  /// Urut low -> medium -> high; kelas lain (kalau ada) menyusul di belakang.
  List<MapEntry<String, double>> _orderedProbs(Prediction result) {
    const List<String> order = <String>['low', 'medium', 'high'];
    final List<MapEntry<String, double>> out = <MapEntry<String, double>>[];
    for (final String name in order) {
      final double? value = result.probabilities[name];
      if (value != null) out.add(MapEntry<String, double>(name, value));
    }
    result.probabilities.forEach((String key, double value) {
      if (!order.contains(key)) out.add(MapEntry<String, double>(key, value));
    });
    return out;
  }

  /// Bar horizontal sederhana berbasis Container, tanpa paket charting.
  Widget _probabilityBar(String label, double value) {
    final double fraction = value.isFinite ? value.clamp(0.0, 1.0) : 0.0;
    final Color color = densityColor(label);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: TextStyle(color: color, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                return ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: Stack(
                    children: <Widget>[
                      Container(height: 14, color: const Color(0xFFE0E0E0)),
                      Container(height: 14, width: constraints.maxWidth * fraction, color: color),
                    ],
                  ),
                );
              },
            ),
          ),
          SizedBox(
            width: 56,
            child: Text('${(fraction * 100).toStringAsFixed(1)}%', textAlign: TextAlign.right),
          ),
        ],
      ),
    );
  }
}
