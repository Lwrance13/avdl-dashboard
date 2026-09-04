// AVDL Dashboard — prototipe APK untuk penelitian prediksi kepadatan lalu lintas.
//
// Empat tab: Prediksi · Jumlah per kelas · Tren waktu · SHAP.
// Seluruh logika ada di file ini; paket eksternal hanya `http` dan `fl_chart`.
//
// LANGKAH TERPISAH (bukan di file ini) — android/app/src/main/AndroidManifest.xml:
//   1. <uses-permission android:name="android.permission.INTERNET"/>
//   2. android:usesCleartextTraffic="true" pada tag <application> — hanya perlu
//      kalau BASE_URL masih HTTP polos (alamat LAN). Domain Railway sudah HTTPS.
//
// Nama field mengikuti backend/main.py yang sebenarnya:
//   GET /samples        -> {total, count, samples:[{id, location, interval_start, true_label}]}
//   GET /stats/counts   -> {location, n_intervals, classes, counts, per_location[]}
//   GET /stats/trend    -> {location, n_points, classes, points:[{interval_start, episode_id, counts}]}
//   GET /shap/top-features -> {top_features[], traffic_signal_pct, bookkeeping_pct, note}

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

// ---------------------------------------------------------------------------
// Konfigurasi
// ---------------------------------------------------------------------------
//
// API key disuntikkan saat build lewat --dart-define, TIDAK ditulis di file ini:
//   flutter build apk --release --dart-define=API_KEY=<kunci> --dart-define=BASE_URL=<url>
//
// Backend menerima DUA kunci yang sama sahnya: API_KEY (admin, tanpa rate limit)
// dan REVIEWER_API_KEY (reviewer, POST /predict dibatasi lajunya -> 429).
// Aplikasi tidak perlu tahu bedanya; ia hanya mengirim nilai define ini.
//
// String.fromEnvironment hanya dievaluasi pada const context — jangan ubah
// `const` di bawah menjadi `final`, nilainya akan selalu kosong.
//
// BATAS PENGAMANAN: kunci di dalam APK tetap bisa diekstrak siapa pun yang
// memegang file APK-nya. --dart-define menjauhkan kunci dari source dan git,
// bukan dari pembongkaran APK. Bukan pengganti autentikasi per pengguna.

/// Dikirim sebagai header `X-API-Key`. Wajib untuk semua endpoint kecuali
/// `GET /health`. Kosong berarti build tanpa --dart-define=API_KEY.
const String kApiKey = String.fromEnvironment('API_KEY');

/// Alamat backend. Default = IP LAN lama, jadi build tanpa define berperilaku
/// seperti versi awal. Untuk APK yang dibagikan WAJIB isi define ini.
const String kBaseUrl = String.fromEnvironment(
  'BASE_URL',
  defaultValue: 'http://192.168.1.6:8000',
);

const Duration kTimeout = Duration(seconds: 12);
const int kPageSize = 50;
const String kAllLocations = 'Semua lokasi';

const Map<String, String> kGetHeaders = <String, String>{'X-API-Key': kApiKey};
const Map<String, String> kJsonHeaders = <String, String>{
  'Content-Type': 'application/json',
  'X-API-Key': kApiKey,
};

// ---------------------------------------------------------------------------
// TOKEN VISUAL
// ---------------------------------------------------------------------------
//
// Nilainya bukan pilihan selera: diambil dari palet data-viz yang sudah lewat
// validator (lightness band, chroma floor, separasi CVD, contrast vs surface).
//
// Kelas kepadatan low/medium/high memakai **ramp ordinal satu warna** (biru),
// bukan hijau/kuning/merah. Alasannya terukur: pada skema lampu-lalin,
// hijau vs kuning hanya berjarak CVD ΔE 3,0 di protanopia — jauh di bawah
// ambang 8 — sehingga pembaca buta warna merah-hijau tidak bisa memisahkan
// "low" dari "medium". Ramp biru ini lulus seluruh pemeriksaan ordinal di
// kedua mode (monoton, gap ΔL >= 0,06, ujung terang >= 2:1 vs surface).
// Nama kelasnya juga selalu ditulis di sebelah warnanya, jadi identitas tidak
// pernah bergantung pada warna saja.
class Viz {
  const Viz({
    required this.surface,
    required this.plane,
    required this.inkPrimary,
    required this.inkSecondary,
    required this.inkMuted,
    required this.grid,
    required this.axis,
    required this.border,
    required this.series1,
    required this.low,
    required this.medium,
    required this.high,
    required this.meterTrack,
  });

  final Color surface; // permukaan kartu/grafik
  final Color plane; // latar halaman
  final Color inkPrimary; // teks utama
  final Color inkSecondary; // teks pendukung
  final Color inkMuted; // label sumbu
  final Color grid; // gridline hairline
  final Color axis; // baseline
  final Color border; // ring hairline kartu
  final Color series1; // satu-satunya warna seri untuk grafik seri tunggal
  final Color low; // ramp ordinal kepadatan
  final Color medium;
  final Color high;
  final Color meterTrack; // track meter = step lebih terang dari ramp yang sama

  static const Viz light = Viz(
    surface: Color(0xFFFCFCFB),
    plane: Color(0xFFF9F9F7),
    inkPrimary: Color(0xFF0B0B0B),
    inkSecondary: Color(0xFF52514E),
    inkMuted: Color(0xFF898781),
    grid: Color(0xFFE1E0D9),
    axis: Color(0xFFC3C2B7),
    border: Color(0x1A0B0B0B),
    series1: Color(0xFF2A78D6),
    low: Color(0xFF86B6EF),
    medium: Color(0xFF2A78D6),
    high: Color(0xFF0D366B),
    meterTrack: Color(0xFF9EC5F4),
  );

  static const Viz dark = Viz(
    surface: Color(0xFF1A1A19),
    plane: Color(0xFF0D0D0D),
    inkPrimary: Color(0xFFFFFFFF),
    inkSecondary: Color(0xFFC3C2B7),
    inkMuted: Color(0xFF898781),
    grid: Color(0xFF2C2C2A),
    axis: Color(0xFF383835),
    border: Color(0x1AFFFFFF),
    series1: Color(0xFF3987E5),
    // Di permukaan gelap arah keterbacaan terbalik: makin padat = makin terang.
    low: Color(0xFF184F95),
    medium: Color(0xFF3987E5),
    high: Color(0xFF9EC5F4),
    meterTrack: Color(0xFF184F95),
  );

  static Viz of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;

  /// Warna untuk satu kelas kepadatan. Selalu dipakai bersama nama kelasnya.
  Color density(String? label) {
    switch ((label ?? '').toLowerCase()) {
      case 'low':
        return low;
      case 'medium':
        return medium;
      case 'high':
        return high;
      default:
        return inkMuted;
    }
  }
}

/// Spasi dasar; kelipatan 4 supaya ritmenya konsisten.
class Gap {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
}

// ---------------------------------------------------------------------------
// MODEL DATA
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
    if (json['scaler_loaded_but_unused'] == true) {
      bits.add('scaler tidak dipakai');
    }
    // Server tanpa kunci sama sekali menolak semua endpoint data dengan 503
    // walaupun /health sendiri tetap menjawab 200.
    if (json['api_key_configured'] == false) {
      bits.add('server: API_KEY belum diset');
    }
    if (json['reviewer_key_configured'] == true) {
      bits.add('kunci reviewer aktif');
    }
    if (error != null) bits.add('load_error: $error');
    return Health(
      modelLoaded: json['model_loaded'] == true,
      detail: bits.join(' · '),
    );
  }
}

/// Hitungan per kelas untuk satu lokasi (GET /stats/counts -> per_location[]).
class LocationCounts {
  const LocationCounts({
    required this.location,
    required this.nIntervals,
    required this.counts,
  });

  final String location;
  final int nIntervals;
  final Map<String, int> counts;

  factory LocationCounts.fromJson(Map<String, dynamic> json) => LocationCounts(
    location: (json['location'] ?? '-').toString(),
    nIntervals: (json['n_intervals'] as num?)?.toInt() ?? 0,
    counts: _intMap(json['counts']),
  );
}

/// GET /stats/counts.
class StatsCounts {
  const StatsCounts({
    required this.nIntervals,
    required this.classes,
    required this.counts,
    required this.perLocation,
  });

  final int nIntervals;
  final List<String> classes;
  final Map<String, int> counts;
  final List<LocationCounts> perLocation;

  factory StatsCounts.fromJson(Map<String, dynamic> json) {
    final List<LocationCounts> per = <LocationCounts>[];
    final Object? raw = json['per_location'];
    if (raw is List) {
      for (final Object? item in raw) {
        if (item is Map<String, dynamic>) {
          per.add(LocationCounts.fromJson(item));
        }
      }
    }
    return StatsCounts(
      nIntervals: (json['n_intervals'] as num?)?.toInt() ?? 0,
      classes: _stringList(json['classes']),
      counts: _intMap(json['counts']),
      perLocation: per,
    );
  }
}

/// Satu titik pada GET /stats/trend.
class TrendPoint {
  const TrendPoint({
    required this.intervalStart,
    required this.episodeId,
    required this.counts,
  });

  final String intervalStart;
  final String episodeId;
  final Map<String, int> counts;

  factory TrendPoint.fromJson(Map<String, dynamic> json) => TrendPoint(
    intervalStart: (json['interval_start'] ?? '').toString(),
    episodeId: (json['episode_id'] ?? '').toString(),
    counts: _intMap(json['counts']),
  );
}

/// GET /stats/trend.
class StatsTrend {
  const StatsTrend({
    required this.location,
    required this.classes,
    required this.points,
  });

  final String location;
  final List<String> classes;
  final List<TrendPoint> points;

  factory StatsTrend.fromJson(Map<String, dynamic> json) {
    final List<TrendPoint> pts = <TrendPoint>[];
    final Object? raw = json['points'];
    if (raw is List) {
      for (final Object? item in raw) {
        if (item is Map<String, dynamic>) pts.add(TrendPoint.fromJson(item));
      }
    }
    return StatsTrend(
      location: (json['location'] ?? '-').toString(),
      classes: _stringList(json['classes']),
      points: pts,
    );
  }

  /// Jumlah episode berbeda pada deret ini. Grafik memutus garis di batasnya.
  int get episodeCount =>
      points.map((TrendPoint p) => p.episodeId).toSet().length;
}

/// GET /shap/top-features.
class ShapInfo {
  const ShapInfo({
    required this.features,
    required this.trafficSignalPct,
    required this.bookkeepingPct,
    required this.note,
  });

  final List<({String feature, double pct})> features;
  final double trafficSignalPct;
  final double bookkeepingPct;
  final String note;

  factory ShapInfo.fromJson(Map<String, dynamic> json) {
    final List<({String feature, double pct})> out =
        <({String feature, double pct})>[];
    final Object? raw = json['top_features'];
    if (raw is List) {
      for (final Object? item in raw) {
        if (item is Map<String, dynamic>) {
          out.add((
            feature: (item['feature'] ?? '?').toString(),
            pct: (item['importance_pct'] as num?)?.toDouble() ?? 0,
          ));
        }
      }
    }
    return ShapInfo(
      features: out,
      trafficSignalPct: (json['traffic_signal_pct'] as num?)?.toDouble() ?? 0,
      bookkeepingPct: (json['bookkeeping_pct'] as num?)?.toDouble() ?? 0,
      note: (json['note'] ?? '').toString(),
    );
  }
}

Map<String, int> _intMap(Object? raw) {
  final Map<String, int> out = <String, int>{};
  if (raw is Map) {
    raw.forEach((Object? key, Object? value) {
      if (value is num) out[key.toString()] = value.toInt();
    });
  }
  return out;
}

List<String> _stringList(Object? raw) {
  final List<String> out = <String>[];
  if (raw is List) {
    for (final Object? item in raw) {
      out.add(item.toString());
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// PANGGILAN API
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
  if (statusCode == 404) {
    return 'Tidak ada data (404) untuk $path.';
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
    return jsonDecode(utf8.decode(res.bodyBytes));
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
  return json is List ? _stringList(json) : <String>[];
}

Future<List<Sample>> fetchSamples({
  String? location,
  int limit = kPageSize,
}) async {
  final StringBuffer path = StringBuffer('/samples?limit=$limit&offset=0');
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

Future<StatsCounts> fetchStatsCounts({String? location}) async {
  final StringBuffer path = StringBuffer('/stats/counts');
  if (location != null && location != kAllLocations) {
    path.write('?location=${Uri.encodeQueryComponent(location)}');
  }
  final Object? json = await _getJson(path.toString());
  if (json is Map<String, dynamic>) return StatsCounts.fromJson(json);
  throw ApiException('Balasan /stats/counts tidak dikenali.');
}

Future<StatsTrend> fetchStatsTrend(String location) async {
  final Object? json = await _getJson(
    '/stats/trend?location=${Uri.encodeQueryComponent(location)}',
  );
  if (json is Map<String, dynamic>) return StatsTrend.fromJson(json);
  throw ApiException('Balasan /stats/trend tidak dikenali.');
}

Future<ShapInfo> fetchShapTopFeatures() async {
  final Object? json = await _getJson('/shap/top-features');
  if (json is Map<String, dynamic>) return ShapInfo.fromJson(json);
  throw ApiException('Balasan /shap/top-features tidak dikenali.');
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
      throw ApiException(
        'Prediksi gagal — ${_httpErrorMessage(res.statusCode, '/predict')}',
      );
    }
    final Object? json = jsonDecode(utf8.decode(res.bodyBytes));
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

// ---------------------------------------------------------------------------
// APP
// ---------------------------------------------------------------------------

void main() => runApp(const AvdlApp());

class AvdlApp extends StatelessWidget {
  const AvdlApp({super.key});

  ThemeData _theme(Brightness brightness) {
    final Viz viz = brightness == Brightness.dark ? Viz.dark : Viz.light;
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: viz.series1,
      brightness: brightness,
    ).copyWith(surface: viz.plane);
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: viz.plane,
      dividerColor: viz.grid,
      appBarTheme: AppBarTheme(
        backgroundColor: viz.plane,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: viz.inkPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: viz.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: viz.series1.withValues(alpha: 0.14),
        elevation: 0,
        height: 68,
        labelTextStyle: WidgetStatePropertyAll<TextStyle>(
          TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w500,
            color: viz.inkSecondary,
          ),
        ),
      ),
      textTheme:
          (brightness == Brightness.dark
                  ? Typography.material2021().white
                  : Typography.material2021().black)
              .apply(bodyColor: viz.inkPrimary, displayColor: viz.inkPrimary),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AVDL Dashboard',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: const AvdlShell(),
    );
  }
}

// ---------------------------------------------------------------------------
// SHELL — navigasi 4 tab, banner status, dan satu baris filter lokasi bersama
// ---------------------------------------------------------------------------
//
// Filter lokasi hidup di shell, bukan di dalam kartu grafik: satu baris filter
// di atas segalanya, dan seluruh tab merender ulang terhadap potongan yang sama.

class AvdlShell extends StatefulWidget {
  const AvdlShell({super.key});

  @override
  State<AvdlShell> createState() => _AvdlShellState();
}

class _AvdlShellState extends State<AvdlShell> {
  int _tab = 0;
  Health? _health;
  String? _healthError;
  bool _checkingHealth = true;

  List<String> _locations = <String>[kAllLocations];
  String _location = kAllLocations;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _checkHealth();
    await _loadLocations();
  }

  Future<void> _checkHealth() async {
    setState(() => _checkingHealth = true);
    try {
      final Health health = await fetchHealth();
      if (!mounted) return;
      setState(() {
        _health = health;
        _healthError = null;
        _checkingHealth = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _health = null;
        _healthError = error.message;
        _checkingHealth = false;
      });
    }
  }

  Future<void> _loadLocations() async {
    try {
      final List<String> found = await fetchLocations();
      if (!mounted || found.isEmpty) return;
      setState(() => _locations = <String>[kAllLocations, ...found]);
    } on ApiException {
      // Dropdown tetap berisi "Semua lokasi"; tab masing-masing yang melaporkan
      // kegagalannya sendiri, supaya shell tidak menampilkan dua pesan error.
    }
  }

  /// Sehat = model termuat DAN kunci sudah disuntikkan. /health tetap 200 tanpa
  /// kunci, jadi tanpa syarat kedua banner akan tampak sehat padahal semua
  /// layar data menjawab 401.
  bool get _backendOk => (_health?.modelLoaded ?? false) && kApiKey.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final Viz viz = Viz.of(context);
    final bool showFilter = _tab == 0 || _tab == 1 || _tab == 2;

    return Scaffold(
      appBar: AppBar(
        title: const Text('AVDL Traffic Density'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Cek ulang backend',
            onPressed: _checkingHealth ? null : _bootstrap,
            icon: _checkingHealth
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: viz.inkMuted,
                    ),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: Gap.xs),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (!_backendOk && !_checkingHealth)
            _StatusBanner(
              title: kApiKey.isEmpty
                  ? 'API key belum disuntikkan'
                  : 'Backend tidak siap',
              detail:
                  _healthError ??
                  (kApiKey.isEmpty
                      ? 'Build ulang dengan --dart-define=API_KEY=<kunci>.'
                      : _health?.detail ?? 'Model belum termuat di server.'),
              onRetry: _bootstrap,
            ),
          if (showFilter)
            _FilterBar(
              locations: _locations,
              value: _location,
              // Tab Tren butuh satu lokasi konkret, jadi "Semua lokasi"
              // dinonaktifkan di sana daripada mengirim permintaan yang pasti gagal.
              allowAll: _tab != 2,
              onChanged: (String next) => setState(() => _location = next),
            ),
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: <Widget>[
                PredictTab(location: _location),
                CountsTab(location: _location),
                TrendTab(location: _location, locations: _locations),
                const ShapTab(),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (int index) => setState(() {
          _tab = index;
          // Tren tidak menerima agregat; pilih lokasi pertama yang nyata.
          if (index == 2 &&
              _location == kAllLocations &&
              _locations.length > 1) {
            _location = _locations[1];
          }
        }),
        destinations: const <NavigationDestination>[
          NavigationDestination(
            icon: Icon(Icons.insights_outlined),
            selectedIcon: Icon(Icons.insights_rounded),
            label: 'Prediksi',
          ),
          NavigationDestination(
            icon: Icon(Icons.bar_chart_outlined),
            selectedIcon: Icon(Icons.bar_chart_rounded),
            label: 'Jumlah',
          ),
          NavigationDestination(
            icon: Icon(Icons.show_chart_outlined),
            selectedIcon: Icon(Icons.show_chart_rounded),
            label: 'Tren',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_tree_outlined),
            selectedIcon: Icon(Icons.account_tree_rounded),
            label: 'SHAP',
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// WIDGET BERSAMA
// ---------------------------------------------------------------------------

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    required this.title,
    required this.detail,
    required this.onRetry,
  });

  final String title;
  final String detail;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final Viz viz = Viz.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.sm, Gap.md),
      color: viz.surface,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.warning_amber_rounded, size: 20, color: viz.inkSecondary),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5,
                    color: viz.inkPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    color: viz.inkSecondary,
                  ),
                ),
              ],
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Cek')),
        ],
      ),
    );
  }
}

/// Satu baris filter di atas seluruh isi tab.
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.locations,
    required this.value,
    required this.allowAll,
    required this.onChanged,
  });

  final List<String> locations;
  final String value;
  final bool allowAll;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final Viz viz = Viz.of(context);
    final List<String> items = allowAll
        ? locations
        : locations.where((String l) => l != kAllLocations).toList();
    final String current = items.contains(value)
        ? value
        : (items.isEmpty ? value : items.first);

    return Container(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.md),
      decoration: BoxDecoration(
        color: viz.plane,
        border: Border(bottom: BorderSide(color: viz.grid)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.place_outlined, size: 18, color: viz.inkMuted),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: current,
                isExpanded: true,
                isDense: true,
                borderRadius: BorderRadius.circular(12),
                style: TextStyle(fontSize: 14, color: viz.inkPrimary),
                items: items
                    .map(
                      (String l) => DropdownMenuItem<String>(
                        value: l,
                        child: Text(l, overflow: TextOverflow.ellipsis),
                      ),
                    )
                    .toList(),
                onChanged: (String? next) {
                  if (next != null) onChanged(next);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Kartu dengan ring hairline, bukan shadow — supaya data yang paling menonjol.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.child,
    this.title,
    this.subtitle,
    this.trailing,
    this.padding = const EdgeInsets.all(Gap.lg),
  });

  final Widget child;
  final String? title;
  final String? subtitle;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final Viz viz = Viz.of(context);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: viz.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: viz.border),
      ),
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (title != null)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        title!,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: viz.inkPrimary,
                        ),
                      ),
                      if (subtitle != null) ...<Widget>[
                        const SizedBox(height: 3),
                        Text(
                          subtitle!,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.35,
                            color: viz.inkSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
          if (title != null) const SizedBox(height: Gap.lg),
          child,
        ],
      ),
    );
  }
}

/// Angka utama tanpa grafik. Nilai memakai figur proporsional (bukan tabular)
/// karena berdiri sendiri dalam ukuran besar.
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.hint,
  });

  final String label;
  final int value;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final Viz viz = Viz.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.md),
      decoration: BoxDecoration(
        color: viz.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: viz.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11.5, color: viz.inkSecondary),
          ),
          const SizedBox(height: Gap.xs),
          Text(
            _thousands(value),
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              height: 1.1,
              color: viz.inkPrimary,
            ),
          ),
          if (hint != null) ...<Widget>[
            const SizedBox(height: 2),
            Text(hint!, style: TextStyle(fontSize: 10.5, color: viz.inkMuted)),
          ],
        ],
      ),
    );
  }
}

/// Chip kelas kepadatan: titik warna + nama kelas. Nama selalu ada, jadi
/// identitas tidak pernah bergantung pada warna saja.
class DensityChip extends StatelessWidget {
  const DensityChip({super.key, required this.label, this.dense = false});

  final String? label;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final Viz viz = Viz.of(context);
    final String text = (label == null || label!.isEmpty) ? '—' : label!;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? Gap.sm : Gap.md,
        vertical: dense ? 3 : 5,
      ),
      decoration: BoxDecoration(
        color: viz.plane,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: viz.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: viz.density(label),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: Gap.sm),
          Text(
            text,
            style: TextStyle(
              fontSize: dense ? 11.5 : 12.5,
              fontWeight: FontWeight.w500,
              color: viz.inkPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

String _thousands(int value) {
  final String digits = value.abs().toString();
  final StringBuffer out = StringBuffer(value < 0 ? '-' : '');
  for (int i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write('.');
    out.write(digits[i]);
  }
  return out.toString();
}

/// Keadaan memuat / error / kosong, seragam di semua tab.
class StateBlock extends StatelessWidget {
  const StateBlock.loading({super.key})
    : message = null,
      icon = null,
      onRetry = null;

  const StateBlock.error(this.message, {super.key, this.onRetry})
    : icon = Icons.error_outline_rounded;

  const StateBlock.empty(this.message, {super.key})
    : icon = Icons.inbox_outlined,
      onRetry = null;

  final String? message;
  final IconData? icon;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final Viz viz = Viz.of(context);
    if (message == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              color: viz.series1,
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.xl, vertical: 40),
      child: Column(
        children: <Widget>[
          Icon(icon, size: 30, color: viz.inkMuted),
          const SizedBox(height: Gap.md),
          Text(
            message!,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: viz.inkSecondary,
            ),
          ),
          if (onRetry != null) ...<Widget>[
            const SizedBox(height: Gap.md),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Coba lagi'),
            ),
          ],
        ],
      ),
    );
  }
}

/// Tombol yang memindahkan grafik ke tabel angka. Setiap grafik punya kembaran
/// tabel supaya tidak ada nilai yang hanya bisa dibaca lewat warna atau hover.
class TableToggle extends StatelessWidget {
  const TableToggle({
    super.key,
    required this.showTable,
    required this.onChanged,
  });

  final bool showTable;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final Viz viz = Viz.of(context);
    return IconButton(
      tooltip: showTable ? 'Tampilkan grafik' : 'Tampilkan tabel angka',
      visualDensity: VisualDensity.compact,
      onPressed: () => onChanged(!showTable),
      icon: Icon(
        showTable ? Icons.bar_chart_rounded : Icons.table_rows_outlined,
        size: 19,
        color: viz.inkSecondary,
      ),
    );
  }
}

/// Tabel dua kolom: nama + nilai. Angka pakai tabular-nums karena berjajar.
class ValueTable extends StatelessWidget {
  const ValueTable({
    super.key,
    required this.rows,
    this.nameHeader = 'Kelas',
    this.valueHeader = 'Jumlah',
  });

  final List<(String, String)> rows;
  final String nameHeader;
  final String valueHeader;

  @override
  Widget build(BuildContext context) {
    final Viz viz = Viz.of(context);
    final TextStyle head = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: viz.inkMuted,
    );
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.sm),
          child: Row(
            children: <Widget>[
              Expanded(child: Text(nameHeader, style: head)),
              Text(valueHeader, style: head),
            ],
          ),
        ),
        for (final (String name, String value) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    name,
                    style: TextStyle(fontSize: 12.5, color: viz.inkSecondary),
                  ),
                ),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: viz.inkPrimary,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// GRAFIK
// ---------------------------------------------------------------------------

/// Batang horizontal, satu seri, satu warna.
///
/// Digambar dengan widget biasa alih-alih fl_chart karena bentuk ini butuh
/// kontrol tepat atas tiga hal: ujung-data membulat 4px sementara pangkalnya
/// tetap siku di baseline, label nilai selalu DI LUAR ujung batang (jadi tidak
/// mungkin terpotong oleh batang pendek), dan nama kategori yang panjang boleh
/// memakai satu baris penuh. Satu seri = tanpa legend; judul kartu yang
/// menyebut apa yang diplot.
class HBarChart extends StatelessWidget {
  const HBarChart({
    super.key,
    required this.rows,
    this.barColor,
    this.barHeight = 10,
    this.valueFormatter,
  });

  final List<(String, double)> rows;
  final Color? barColor;
  final double barHeight;
  final String Function(double)? valueFormatter;

  @override
  Widget build(BuildContext context) {
    final Viz viz = Viz.of(context);
    final Color fill = barColor ?? viz.series1;
    final double max = rows.fold<double>(
      0,
      (double acc, (String, double) r) => math.max(acc, r.$2),
    );
    final String Function(double) fmt =
        valueFormatter ?? (double v) => _thousands(v.round());

    return Column(
      children: <Widget>[
        for (final (String name, double value) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: viz.inkSecondary),
                      ),
                    ),
                    const SizedBox(width: Gap.sm),
                    Text(
                      fmt(value),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: viz.inkPrimary,
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Gap.xs),
                LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final double frac = max <= 0 ? 0 : value / max;
                    // Nilai bukan-nol tetap menyisakan sliver 3px supaya "1"
                    // tidak tampak identik dengan "0".
                    final double width = frac <= 0
                        ? 0
                        : math.max(3, frac * constraints.maxWidth);
                    return Stack(
                      children: <Widget>[
                        Container(
                          height: barHeight,
                          decoration: BoxDecoration(
                            color: viz.grid,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        Container(
                          height: barHeight,
                          width: width,
                          decoration: BoxDecoration(
                            color: fill,
                            borderRadius: const BorderRadius.only(
                              topRight: Radius.circular(4),
                              bottomRight: Radius.circular(4),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Garis waktu satu kelas, **sadar batas episode**.
///
/// Rekaman AVDL terputus-putus: satu lokasi bisa berisi beberapa episode yang
/// berjarak berjam-jam. Menyambungkan dua episode jadi satu garis akan
/// menyiratkan kontinuitas yang tidak ada, jadi setiap episode digambar sebagai
/// LineChartBarData tersendiri — garisnya benar-benar terputus di batas.
class EpisodeLineChart extends StatelessWidget {
  const EpisodeLineChart({
    super.key,
    required this.points,
    required this.className,
    this.height = 132,
  });

  final List<TrendPoint> points;
  final String className;
  final double height;

  @override
  Widget build(BuildContext context) {
    final Viz viz = Viz.of(context);

    // Pecah menjadi segmen per episode, pertahankan indeks x global supaya
    // jeda antar episode terlihat sebagai celah, bukan dirapatkan.
    final List<List<FlSpot>> segments = <List<FlSpot>>[];
    String? currentEpisode;
    for (int i = 0; i < points.length; i++) {
      final TrendPoint p = points[i];
      final double y = (p.counts[className] ?? 0).toDouble();
      if (p.episodeId != currentEpisode) {
        segments.add(<FlSpot>[]);
        currentEpisode = p.episodeId;
      }
      segments.last.add(FlSpot(i.toDouble(), y));
    }

    double maxY = 0;
    for (final TrendPoint p in points) {
      maxY = math.max(maxY, (p.counts[className] ?? 0).toDouble());
    }
    // Sedikit ruang di atas puncak, dan minimum 4 supaya deret nol tidak
    // menghasilkan sumbu yang runtuh.
    final double top = math.max(4, maxY * 1.25);
    final double interval = math.max(1, (top / 2).ceilToDouble());

    return SizedBox(
      height: height,
      child: LineChart(
        LineChartData(
          minX: 0,
          maxX: math.max(1, (points.length - 1).toDouble()),
          minY: 0,
          maxY: top,
          clipData: const FlClipData.all(),
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: interval,
            getDrawingHorizontalLine: (double value) =>
                FlLine(color: viz.grid, strokeWidth: 1),
          ),
          borderData: FlBorderData(
            show: true,
            border: Border(bottom: BorderSide(color: viz.axis, width: 1)),
          ),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            bottomTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 34,
                interval: interval,
                getTitlesWidget: (double value, TitleMeta meta) {
                  if (value > top - interval * 0.4) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(right: Gap.xs),
                    child: Text(
                      _thousands(value.round()),
                      style: TextStyle(
                        fontSize: 10,
                        color: viz.inkMuted,
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (LineBarSpot spot) => viz.inkPrimary,
              tooltipRoundedRadius: 8,
              getTooltipItems: (List<LineBarSpot> spots) => spots
                  .map(
                    (LineBarSpot s) => LineTooltipItem(
                      '${_thousands(s.y.round())}\n'
                      '${_shortTime(points[s.x.round().clamp(0, points.length - 1)].intervalStart)}',
                      TextStyle(
                        color: viz.surface,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
          lineBarsData: <LineChartBarData>[
            for (final List<FlSpot> segment in segments)
              LineChartBarData(
                spots: segment,
                isCurved: false,
                color: viz.series1,
                barWidth: 2,
                isStrokeCapRound: true,
                // Titik hanya ditampilkan kalau satu episode terlalu pendek
                // untuk membentuk garis — kalau tidak, tiap interval jadi noise.
                dotData: FlDotData(
                  show: segment.length == 1,
                  getDotPainter:
                      (FlSpot spot, double pct, LineChartBarData bar, int i) =>
                          FlDotCirclePainter(
                            radius: 4,
                            color: viz.series1,
                            strokeWidth: 2,
                            strokeColor: viz.surface,
                          ),
                ),
                belowBarData: BarAreaData(
                  show: true,
                  color: viz.series1.withValues(alpha: 0.10),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// "2019-09-10 14:00:00" -> "10 Sep 14:00". Kalau formatnya tak dikenali,
/// nilainya dikembalikan apa adanya.
String _shortTime(String raw) {
  final DateTime? parsed = DateTime.tryParse(raw.replaceFirst(' ', 'T'));
  if (parsed == null) return raw;
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
  final String hh = parsed.hour.toString().padLeft(2, '0');
  final String mm = parsed.minute.toString().padLeft(2, '0');
  return '${parsed.day} ${months[parsed.month - 1]} $hh:$mm';
}

// ---------------------------------------------------------------------------
// TAB 1 — PREDIKSI
// ---------------------------------------------------------------------------

class PredictTab extends StatefulWidget {
  const PredictTab({super.key, required this.location});

  final String location;

  @override
  State<PredictTab> createState() => _PredictTabState();
}

class _PredictTabState extends State<PredictTab> {
  List<Sample>? _samples;
  String? _error;
  int? _openId;
  final Map<int, Prediction> _cache = <int, Prediction>{};
  final Set<int> _pending = <int>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(PredictTab old) {
    super.didUpdateWidget(old);
    if (old.location != widget.location) _load();
  }

  Future<void> _load() async {
    setState(() {
      _samples = null;
      _error = null;
      _openId = null;
    });
    try {
      final List<Sample> found = await fetchSamples(location: widget.location);
      if (!mounted) return;
      setState(() => _samples = found);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    }
  }

  /// Prediksi di-cache per sample supaya membuka baris yang sama dua kali tidak
  /// memanggil /predict lagi — relevan sekarang karena kunci reviewer dibatasi.
  Future<void> _toggle(Sample sample) async {
    if (_openId == sample.id) {
      setState(() => _openId = null);
      return;
    }
    setState(() => _openId = sample.id);
    if (_cache.containsKey(sample.id) || _pending.contains(sample.id)) return;

    setState(() => _pending.add(sample.id));
    try {
      final Prediction prediction = await postPredict(sample.id);
      if (!mounted) return;
      setState(() {
        _cache[sample.id] = prediction;
        _pending.remove(sample.id);
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _pending.remove(sample.id));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.message),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final Viz viz = Viz.of(context);
    if (_error != null) return StateBlock.error(_error!, onRetry: _load);
    if (_samples == null) return const StateBlock.loading();
    if (_samples!.isEmpty) {
      return const StateBlock.empty('Tidak ada interval uji untuk lokasi ini.');
    }

    return RefreshIndicator(
      onRefresh: _load,
      color: viz.series1,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 32),
        itemCount: _samples!.length + 1,
        separatorBuilder: (BuildContext _, int _) =>
            const SizedBox(height: Gap.sm),
        itemBuilder: (BuildContext context, int index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: Text(
                '${_samples!.length} interval uji — ketuk satu baris untuk memprediksi '
                'kelas kepadatan interval berikutnya.',
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.4,
                  color: viz.inkSecondary,
                ),
              ),
            );
          }
          final Sample sample = _samples![index - 1];
          return _SampleRow(
            sample: sample,
            expanded: _openId == sample.id,
            loading: _pending.contains(sample.id),
            prediction: _cache[sample.id],
            onTap: () => _toggle(sample),
          );
        },
      ),
    );
  }
}

class _SampleRow extends StatelessWidget {
  const _SampleRow({
    required this.sample,
    required this.expanded,
    required this.loading,
    required this.prediction,
    required this.onTap,
  });

  final Sample sample;
  final bool expanded;
  final bool loading;
  final Prediction? prediction;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Viz viz = Viz.of(context);
    return Container(
      decoration: BoxDecoration(
        color: viz.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: expanded ? viz.series1.withValues(alpha: 0.45) : viz.border,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Gap.lg,
                vertical: Gap.md,
              ),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 34,
                    child: Text(
                      '#${sample.id}',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: viz.inkMuted,
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          sample.location,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w500,
                            color: viz.inkPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _shortTime(sample.timestamp),
                          style: TextStyle(
                            fontSize: 11.5,
                            color: viz.inkSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: Gap.sm),
                  DensityChip(label: sample.trueLabel, dense: true),
                  Icon(
                    expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 20,
                    color: viz.inkMuted,
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: viz.plane,
                border: Border(top: BorderSide(color: viz.border)),
              ),
              padding: const EdgeInsets.all(Gap.lg),
              child: loading
                  ? Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: viz.series1,
                        ),
                      ),
                    )
                  : prediction == null
                  ? Text(
                      'Prediksi tidak tersedia.',
                      style: TextStyle(fontSize: 12.5, color: viz.inkSecondary),
                    )
                  : _PredictionPanel(prediction: prediction!),
            ),
        ],
      ),
    );
  }
}

/// Panel hasil prediksi.
///
/// Benar/salah ditandai **ikon + teks dalam tinta netral**, bukan hijau/merah.
/// Alasannya: warna hijau-kuning-merah pada layar ini sudah tidak dipakai untuk
/// apa pun, dan menambahkan sistem warna kedua (status) di sebelah ramp
/// kepadatan akan membuat dua makna bersaing pada palet yang sama.
/// Ketiga probabilitas selalu ditampilkan; yang tertinggi diberi label langsung.
class _PredictionPanel extends StatelessWidget {
  const _PredictionPanel({required this.prediction});

  final Prediction prediction;

  @override
  Widget build(BuildContext context) {
    final Viz viz = Viz.of(context);
    final bool? correct = prediction.isCorrect;
    const List<String> order = <String>['low', 'medium', 'high'];
    final List<String> keys = <String>[
      ...order.where(prediction.probabilities.containsKey),
      ...prediction.probabilities.keys.where((String k) => !order.contains(k)),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              'Prediksi',
              style: TextStyle(fontSize: 11.5, color: viz.inkMuted),
            ),
            const SizedBox(width: Gap.sm),
            DensityChip(label: prediction.predictedLabel),
            const Spacer(),
            if (correct != null)
              Row(
                children: <Widget>[
                  Icon(
                    correct
                        ? Icons.check_circle_outline_rounded
                        : Icons.cancel_outlined,
                    size: 17,
                    color: viz.inkSecondary,
                  ),
                  const SizedBox(width: Gap.xs),
                  Text(
                    correct ? 'Benar' : 'Salah',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: viz.inkPrimary,
                    ),
                  ),
                ],
              ),
          ],
        ),
        if (prediction.trueLabel != null &&
            prediction.trueLabel!.isNotEmpty) ...<Widget>[
          const SizedBox(height: Gap.sm),
          Row(
            children: <Widget>[
              Text(
                'Label sebenarnya',
                style: TextStyle(fontSize: 11.5, color: viz.inkMuted),
              ),
              const SizedBox(width: Gap.sm),
              DensityChip(label: prediction.trueLabel, dense: true),
            ],
          ),
        ],
        const SizedBox(height: Gap.lg),
        Text(
          'Probabilitas per kelas',
          style: TextStyle(fontSize: 11.5, color: viz.inkMuted),
        ),
        const SizedBox(height: Gap.sm),
        for (final String key in keys)
          _ProbabilityRow(
            label: key,
            value: prediction.probabilities[key] ?? 0,
            emphasised:
                key.toLowerCase() == prediction.predictedLabel.toLowerCase(),
          ),
      ],
    );
  }
}

class _ProbabilityRow extends StatelessWidget {
  const _ProbabilityRow({
    required this.label,
    required this.value,
    required this.emphasised,
  });

  final String label;
  final double value;
  final bool emphasised;

  @override
  Widget build(BuildContext context) {
    final Viz viz = Viz.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 62,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: emphasised ? FontWeight.w600 : FontWeight.w400,
                color: emphasised ? viz.inkPrimary : viz.inkSecondary,
              ),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final double width = (value.clamp(0, 1) * constraints.maxWidth)
                    .toDouble();
                return Stack(
                  children: <Widget>[
                    Container(
                      height: 10,
                      decoration: BoxDecoration(
                        color: viz.grid,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Container(
                      height: 10,
                      width: width,
                      decoration: BoxDecoration(
                        color: viz.density(label),
                        borderRadius: const BorderRadius.only(
                          topRight: Radius.circular(4),
                          bottomRight: Radius.circular(4),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(width: Gap.md),
          SizedBox(
            width: 46,
            child: Text(
              '${(value * 100).toStringAsFixed(1)}%',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 12,
                fontWeight: emphasised ? FontWeight.w600 : FontWeight.w400,
                color: emphasised ? viz.inkPrimary : viz.inkSecondary,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// TAB 2 — JUMLAH PER KELAS
// ---------------------------------------------------------------------------
//
// Bentuknya small multiples, bukan satu grouped bar berisi enam seri, dan itu
// karena bentuk datanya: pada split uji Vehicles 45x lebih besar dari Trucks dan
// Scooters hampir nol. Enam seri pada satu sumbu akan membuat lima di antaranya
// tak terlihat. Satu panel per kelas dengan skala sendiri membuat perbandingan
// ANTAR LOKASI terbaca untuk setiap kelas — dan karena setiap panel hanya punya
// satu seri, tidak perlu legend sama sekali.

class CountsTab extends StatefulWidget {
  const CountsTab({super.key, required this.location});

  final String location;

  @override
  State<CountsTab> createState() => _CountsTabState();
}

class _CountsTabState extends State<CountsTab> {
  StatsCounts? _stats;
  String? _error;
  bool _table = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CountsTab old) {
    super.didUpdateWidget(old);
    if (old.location != widget.location) _load();
  }

  Future<void> _load() async {
    setState(() {
      _stats = null;
      _error = null;
    });
    try {
      final StatsCounts found = await fetchStatsCounts(
        location: widget.location,
      );
      if (!mounted) return;
      setState(() => _stats = found);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Viz viz = Viz.of(context);
    if (_error != null) return StateBlock.error(_error!, onRetry: _load);
    if (_stats == null) return const StateBlock.loading();

    final StatsCounts stats = _stats!;
    final List<String> classes = stats.classes.isEmpty
        ? stats.counts.keys.toList()
        : stats.classes;
    final bool multi = stats.perLocation.length > 1;

    return RefreshIndicator(
      onRefresh: _load,
      color: viz.series1,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 32),
        children: <Widget>[
          Text(
            'Diagregasi dari ${_thousands(stats.nIntervals)} interval split uji '
            '${multi ? 'di ${stats.perLocation.length} lokasi' : ''}'
            '. Bukan statistik seluruh dataset.',
            style: TextStyle(
              fontSize: 12.5,
              height: 1.4,
              color: viz.inkSecondary,
            ),
          ),
          const SizedBox(height: Gap.lg),

          // KPI row — enam angka headline. Bukan grafik: angkanya sendiri
          // yang jadi isinya.
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: Gap.sm,
            crossAxisSpacing: Gap.sm,
            childAspectRatio: 1.35,
            children: <Widget>[
              for (final String name in classes)
                StatTile(label: name, value: stats.counts[name] ?? 0),
            ],
          ),
          const SizedBox(height: Gap.lg),

          if (multi)
            SectionCard(
              title: 'Perbandingan antar lokasi',
              subtitle:
                  'Satu panel per kelas, masing-masing berskala sendiri — '
                  'sehingga kelas kecil tetap terbaca di sebelah Vehicles.',
              trailing: TableToggle(
                showTable: _table,
                onChanged: (bool next) => setState(() => _table = next),
              ),
              child: _table
                  ? _countsTable(stats, classes)
                  : Column(
                      children: <Widget>[
                        for (int i = 0; i < classes.length; i++) ...<Widget>[
                          if (i > 0) ...<Widget>[
                            const SizedBox(height: Gap.lg),
                            Divider(height: 1, color: viz.grid),
                            const SizedBox(height: Gap.lg),
                          ],
                          _ClassPanel(
                            className: classes[i],
                            total: stats.counts[classes[i]] ?? 0,
                            perLocation: stats.perLocation,
                          ),
                        ],
                      ],
                    ),
            )
          else
            SectionCard(
              title: 'Jumlah per kelas',
              subtitle: stats.perLocation.isEmpty
                  ? null
                  : '${stats.perLocation.first.location} · '
                        '${_thousands(stats.perLocation.first.nIntervals)} interval',
              trailing: TableToggle(
                showTable: _table,
                onChanged: (bool next) => setState(() => _table = next),
              ),
              child: _table
                  ? ValueTable(
                      rows: <(String, String)>[
                        for (final String name in classes)
                          (name, _thousands(stats.counts[name] ?? 0)),
                      ],
                    )
                  : HBarChart(
                      rows: <(String, double)>[
                        for (final String name in classes)
                          (name, (stats.counts[name] ?? 0).toDouble()),
                      ],
                    ),
            ),
        ],
      ),
    );
  }

  Widget _countsTable(StatsCounts stats, List<String> classes) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (int i = 0; i < classes.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: Gap.lg),
          Text(
            classes[i],
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Viz.of(context).inkPrimary,
            ),
          ),
          const SizedBox(height: Gap.sm),
          ValueTable(
            nameHeader: 'Lokasi',
            rows: <(String, String)>[
              for (final LocationCounts loc in stats.perLocation)
                (loc.location, _thousands(loc.counts[classes[i]] ?? 0)),
            ],
          ),
        ],
      ],
    );
  }
}

/// Satu panel small-multiple: nama kelas + totalnya + batang per lokasi.
class _ClassPanel extends StatelessWidget {
  const _ClassPanel({
    required this.className,
    required this.total,
    required this.perLocation,
  });

  final String className;
  final int total;
  final List<LocationCounts> perLocation;

  @override
  Widget build(BuildContext context) {
    final Viz viz = Viz.of(context);
    final List<(String, double)> rows = <(String, double)>[
      for (final LocationCounts loc in perLocation)
        (loc.location, (loc.counts[className] ?? 0).toDouble()),
    ]..sort(((String, double) a, (String, double) b) => b.$2.compareTo(a.$2));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                className,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: viz.inkPrimary,
                ),
              ),
            ),
            Text(
              'total ${_thousands(total)}',
              style: TextStyle(
                fontSize: 11.5,
                color: viz.inkMuted,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: Gap.sm),
        HBarChart(rows: rows, barHeight: 8),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// TAB 3 — TREN WAKTU
// ---------------------------------------------------------------------------

class TrendTab extends StatefulWidget {
  const TrendTab({super.key, required this.location, required this.locations});

  final String location;
  final List<String> locations;

  @override
  State<TrendTab> createState() => _TrendTabState();
}

class _TrendTabState extends State<TrendTab> {
  StatsTrend? _trend;
  String? _error;
  bool _table = false;
  String? _loadedFor;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(TrendTab old) {
    super.didUpdateWidget(old);
    if (old.location != widget.location) _load();
  }

  String? get _target {
    if (widget.location != kAllLocations) return widget.location;
    final Iterable<String> real = widget.locations.where(
      (String l) => l != kAllLocations,
    );
    return real.isEmpty ? null : real.first;
  }

  Future<void> _load() async {
    final String? target = _target;
    if (target == null) {
      setState(() {
        _trend = null;
        _error = 'Daftar lokasi belum termuat.';
      });
      return;
    }
    setState(() {
      _trend = null;
      _error = null;
      _loadedFor = target;
    });
    try {
      final StatsTrend found = await fetchStatsTrend(target);
      if (!mounted) return;
      setState(() => _trend = found);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Viz viz = Viz.of(context);
    if (_error != null) return StateBlock.error(_error!, onRetry: _load);
    if (_trend == null) return const StateBlock.loading();

    final StatsTrend trend = _trend!;
    if (trend.points.isEmpty) {
      return const StateBlock.empty(
        'Lokasi ini tidak punya interval untuk diplot.',
      );
    }
    final List<String> classes = trend.classes.isEmpty
        ? trend.points.first.counts.keys.toList()
        : trend.classes;
    final int episodes = trend.episodeCount;

    return RefreshIndicator(
      onRefresh: _load,
      color: viz.series1,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 32),
        children: <Widget>[
          Text(
            '${_thousands(trend.points.length)} interval 5 menit di '
            '${_loadedFor ?? trend.location}, '
            '${_shortTime(trend.points.first.intervalStart)} – '
            '${_shortTime(trend.points.last.intervalStart)}.',
            style: TextStyle(
              fontSize: 12.5,
              height: 1.4,
              color: viz.inkSecondary,
            ),
          ),
          const SizedBox(height: Gap.xs),
          Text(
            episodes > 1
                ? '$episodes episode rekaman — garis sengaja terputus di batas '
                      'episode, karena jeda di antaranya bisa berjam-jam.'
                : 'Satu episode rekaman berkelanjutan.',
            style: TextStyle(fontSize: 11.5, height: 1.4, color: viz.inkMuted),
          ),
          const SizedBox(height: Gap.lg),
          SectionCard(
            title: 'Tren per kelas',
            subtitle: 'Setiap panel berskala sendiri; sumbu waktunya sama.',
            trailing: TableToggle(
              showTable: _table,
              onChanged: (bool next) => setState(() => _table = next),
            ),
            child: _table
                ? _trendTable(trend, classes)
                : Column(
                    children: <Widget>[
                      for (int i = 0; i < classes.length; i++) ...<Widget>[
                        if (i > 0) const SizedBox(height: Gap.xl),
                        _TrendPanel(
                          className: classes[i],
                          points: trend.points,
                        ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  /// Tabel kembaran: total dan puncak per kelas, plus waktu puncaknya.
  Widget _trendTable(StatsTrend trend, List<String> classes) {
    final List<(String, String)> rows = <(String, String)>[];
    for (final String name in classes) {
      int total = 0;
      int peak = 0;
      String peakAt = '';
      for (final TrendPoint p in trend.points) {
        final int v = p.counts[name] ?? 0;
        total += v;
        if (v > peak) {
          peak = v;
          peakAt = p.intervalStart;
        }
      }
      rows.add((
        name,
        '${_thousands(total)}  ·  puncak ${_thousands(peak)}'
            '${peakAt.isEmpty ? '' : ' @ ${_shortTime(peakAt)}'}',
      ));
    }
    return ValueTable(rows: rows, valueHeader: 'Total · puncak');
  }
}

/// Satu panel tren: nama kelas, puncaknya sebagai label langsung, lalu grafik.
/// Label dipasang selektif (hanya puncak) — bukan angka di setiap titik.
class _TrendPanel extends StatelessWidget {
  const _TrendPanel({required this.className, required this.points});

  final String className;
  final List<TrendPoint> points;

  @override
  Widget build(BuildContext context) {
    final Viz viz = Viz.of(context);
    int peak = 0;
    for (final TrendPoint p in points) {
      peak = math.max(peak, p.counts[className] ?? 0);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                className,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: viz.inkPrimary,
                ),
              ),
            ),
            Text(
              peak == 0 ? 'tidak ada' : 'puncak ${_thousands(peak)}',
              style: TextStyle(
                fontSize: 11.5,
                color: viz.inkMuted,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: Gap.sm),
        if (peak == 0)
          Container(
            height: 44,
            alignment: Alignment.centerLeft,
            child: Text(
              'Nol di seluruh rentang.',
              style: TextStyle(fontSize: 12, color: viz.inkMuted),
            ),
          )
        else
          EpisodeLineChart(points: points, className: className),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// TAB 4 — SHAP
// ---------------------------------------------------------------------------

class ShapTab extends StatefulWidget {
  const ShapTab({super.key});

  @override
  State<ShapTab> createState() => _ShapTabState();
}

class _ShapTabState extends State<ShapTab> {
  ShapInfo? _shap;
  String? _error;
  bool _table = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _shap = null;
      _error = null;
    });
    try {
      final ShapInfo found = await fetchShapTopFeatures();
      if (!mounted) return;
      setState(() => _shap = found);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Viz viz = Viz.of(context);
    if (_error != null) return StateBlock.error(_error!, onRetry: _load);
    if (_shap == null) return const StateBlock.loading();
    final ShapInfo shap = _shap!;

    return RefreshIndicator(
      onRefresh: _load,
      color: viz.series1,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, 32),
        children: <Widget>[
          SectionCard(
            title: 'Sinyal lalu lintas vs bookkeeping',
            subtitle:
                'Pembagian total mean |SHAP| antara 41 fitur sinyal lalu '
                'lintas dan 5 kolom yang menggambarkan cara rekaman diambil.',
            child: _SplitMeter(
              trafficPct: shap.trafficSignalPct,
              bookkeepingPct: shap.bookkeepingPct,
            ),
          ),
          const SizedBox(height: Gap.lg),
          SectionCard(
            title: 'Lima fitur teratas',
            subtitle: 'Kontribusi masing-masing terhadap total mean |SHAP|.',
            trailing: TableToggle(
              showTable: _table,
              onChanged: (bool next) => setState(() => _table = next),
            ),
            child: shap.features.isEmpty
                ? Text(
                    'Backend tidak mengembalikan daftar fitur.',
                    style: TextStyle(fontSize: 12.5, color: viz.inkSecondary),
                  )
                : _table
                ? ValueTable(
                    nameHeader: 'Fitur',
                    valueHeader: 'Kontribusi',
                    rows: <(String, String)>[
                      for (final ({String feature, double pct}) f
                          in shap.features)
                        (f.feature, '${f.pct.toStringAsFixed(2)}%'),
                    ],
                  )
                : HBarChart(
                    rows: <(String, double)>[
                      for (final ({String feature, double pct}) f
                          in shap.features)
                        (f.feature, f.pct),
                    ],
                    valueFormatter: (double v) => '${v.toStringAsFixed(2)}%',
                  ),
          ),
          if (shap.note.isNotEmpty) ...<Widget>[
            const SizedBox(height: Gap.lg),
            Text(
              shap.note,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.45,
                color: viz.inkMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Meter satu-banding-sisanya. Dua segmen adalah dua langkah dari ramp biru
/// yang SAMA (bukan dua hue), karena ini pembagian satu besaran — bukan dua
/// identitas. Keduanya diberi label langsung, jadi tidak ada nilai yang hanya
/// terbaca dari warna. Sebuah pie dua irisan akan jadi anti-pola di sini.
class _SplitMeter extends StatelessWidget {
  const _SplitMeter({required this.trafficPct, required this.bookkeepingPct});

  final double trafficPct;
  final double bookkeepingPct;

  @override
  Widget build(BuildContext context) {
    final Viz viz = Viz.of(context);
    final double total = (trafficPct + bookkeepingPct) <= 0
        ? 100
        : trafficPct + bookkeepingPct;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '${trafficPct.toStringAsFixed(2)}%',
          style: TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.w600,
            height: 1.05,
            color: viz.inkPrimary,
          ),
        ),
        Text(
          'sinyal lalu lintas',
          style: TextStyle(fontSize: 12.5, color: viz.inkSecondary),
        ),
        const SizedBox(height: Gap.lg),
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            // Celah 2px dalam warna surface yang memisahkan kedua segmen —
            // bukan garis tepi yang digambar di sekelilingnya.
            final double width = constraints.maxWidth;
            final double left = ((trafficPct / total) * width)
                .clamp(0, width)
                .toDouble();
            return SizedBox(
              height: 12,
              child: Row(
                children: <Widget>[
                  Container(
                    width: math.max(0, left - 1),
                    decoration: BoxDecoration(
                      color: viz.series1,
                      borderRadius: const BorderRadius.horizontal(
                        left: Radius.circular(3),
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: viz.meterTrack,
                        borderRadius: const BorderRadius.horizontal(
                          right: Radius.circular(3),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: Gap.md),
        Row(
          children: <Widget>[
            _MeterKey(
              color: viz.series1,
              label: 'Sinyal lalu lintas',
              pct: trafficPct,
            ),
            const SizedBox(width: Gap.lg),
            _MeterKey(
              color: viz.meterTrack,
              label: 'Bookkeeping',
              pct: bookkeepingPct,
            ),
          ],
        ),
      ],
    );
  }
}

class _MeterKey extends StatelessWidget {
  const _MeterKey({
    required this.color,
    required this.label,
    required this.pct,
  });

  final Color color;
  final String label;
  final double pct;

  @override
  Widget build(BuildContext context) {
    final Viz viz = Viz.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: Gap.sm),
        Text(
          '$label ${pct.toStringAsFixed(2)}%',
          style: TextStyle(fontSize: 11.5, color: viz.inkSecondary),
        ),
      ],
    );
  }
}
