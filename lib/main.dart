import 'dart:convert';
import 'dart:io';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mjpeg_view/mjpeg_view.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  runApp(const IoTMobileApp());
}

// ══════════════════════════════════════════════════════════════════════════
// DESIGN TOKENS
// ══════════════════════════════════════════════════════════════════════════
class C {
  static const bg = Color(0xFF0A0A0B); // Pure black base
  static const surface = Color(0xFF131314); // Level 0
  static const surfaceLow = Color(0xFF1C1B1C); // Level 1
  static const surfaceHigh = Color(0xFF2A2A2B); // Level 2 — cards
  static const surfaceHighest = Color(0xFF353436); // Level 3 — interactive

  // Accents
  static const emerald = Color(0xFF4EDEA3); // primary — connected
  static const emeraldDim = Color(0xFF0D2E22);
  static const iceBlue = Color(0xFF0566D9); // secondary — forecast
  static const iceBlueBright = Color(0xFFADC6FF); // secondary light
  static const roseRed = Color(0xFF79000E); // tertiary — anomaly
  static const roseRedBright = Color(0xFFFF6B6B);
  static const amber = Color(0xFFF4A92A); // export / warn

  // Text
  static const textPrimary = Color(0xFFE8F0EB); // on-surface
  static const textSecondary = Color(0xFFBBCABF); // on-surface-variant
  static const textMuted = Color(0xFF6B7F72); // subdued

  // Ghost border
  static const ghostBorder = Color(0x26BBCABF); // 15% opacity outline

  // Anomaly highlight row
  static const anomalyRow = Color(0x1479000E);
}

// ══════════════════════════════════════════════════════════════════════════
// DATA MODEL
// ══════════════════════════════════════════════════════════════════════════
class SensorLog {
  final DateTime time;
  final double speed, pitch, roll, yaw, ax, ay, az, lat, lng;
  SensorLog({
    required this.time,
    required this.speed,
    required this.pitch,
    required this.roll,
    required this.yaw,
    required this.ax,
    required this.ay,
    required this.az,
    required this.lat,
    required this.lng,
  });
  String toCsv() =>
      '${time.toIso8601String()},$speed,$pitch.value,$roll.value,$yaw.value,$ax.value,$ay.value,$az.value,$lat,$lng';
}

// ══════════════════════════════════════════════════════════════════════════
// HOLT'S DOUBLE EXPONENTIAL SMOOTHING
// ══════════════════════════════════════════════════════════════════════════
class HoltForecaster {
  final double alpha, beta;
  final bool isAngular;
  double _level = 0, _trend = 0;
  bool _initialized = false;

  // Rolling window for baseline adaptation
  final List<double> _window = [];
  static const int _windowSize = 100;

  HoltForecaster({this.alpha = 0.3, this.beta = 0.1, this.isAngular = false});

  double _angDiff(double target, double source) {
    double diff = target - source;
    while (diff > 180) {
      diff -= 360;
    }
    while (diff < -180) {
      diff += 360;
    }
    return diff;
  }

  void update(double x) {
    if (!_initialized) {
      _level = x;
      _trend = 0;
      _initialized = true;
    } else {
      if (isAngular) {
        double newLevelUnwrapped =
            (_level + _trend) + alpha * _angDiff(x, _level + _trend);
        double levelDiff = _angDiff(newLevelUnwrapped, _level);
        _trend = _trend + beta * (levelDiff - _trend);

        _level = newLevelUnwrapped;
        while (_level > 180) {
          _level -= 360;
        }
        while (_level < -180) {
          _level += 360;
        }
      } else {
        final prev = _level;
        _level = alpha * x + (1 - alpha) * (_level + _trend);
        _trend = beta * (_level - prev) + (1 - beta) * _trend;
      }
    }

    _window.add(x);
    if (_window.length > _windowSize) {
      _window.removeAt(0);
    }
  }

  List<double> forecast(int steps) {
    if (!_initialized) return List.filled(steps, 0);
    return List.generate(steps, (k) {
      double f = _level + (k + 1) * _trend;
      if (isAngular) {
        while (f > 180) {
          f -= 360;
        }
        while (f < -180) {
          f += 360;
        }
      }
      return f;
    });
  }

  double get stdDev {
    if (_window.length < 2) return 0;
    if (isAngular) {
      double sumSin = 0, sumCos = 0;
      for (final val in _window) {
        sumSin += math.sin(val * math.pi / 180.0);
        sumCos += math.cos(val * math.pi / 180.0);
      }
      sumSin /= _window.length;
      sumCos /= _window.length;
      double R = math.sqrt(sumSin * sumSin + sumCos * sumCos);
      if (R >= 1.0) return 0.0;
      return math.sqrt(-2.0 * math.log(R)) * 180.0 / math.pi;
    } else {
      final m = mean;
      double sumSq = 0;
      for (final val in _window) {
        sumSq += (val - m) * (val - m);
      }
      return math.sqrt(sumSq / (_window.length - 1));
    }
  }

  double get mean {
    if (_window.isEmpty) return 0;
    if (isAngular) {
      double sumSin = 0, sumCos = 0;
      for (final val in _window) {
        sumSin += math.sin(val * math.pi / 180.0);
        sumCos += math.cos(val * math.pi / 180.0);
      }
      return math.atan2(sumSin, sumCos) * 180.0 / math.pi;
    } else {
      double sum = 0;
      for (final val in _window) {
        sum += val;
      }
      return sum / _window.length;
    }
  }

  double zScore(double x) {
    final s = stdDev;
    if (s == 0) return 0;
    if (isAngular) {
      return _angDiff(x, mean) / s;
    }
    return (x - mean) / s;
  }

  bool isAnomaly(double x, {double threshold = 2.5}) =>
      zScore(x).abs() > threshold;
  double confidenceHalfWidth(int k) => 1.96 * stdDev * math.sqrt(k.toDouble());
  bool get ready => _window.length >= 5;
}

// ══════════════════════════════════════════════════════════════════════════
// KALMAN FILTER — 2-D GPS POSITION + SPEED
// ══════════════════════════════════════════════════════════════════════════
class KalmanGPS {
  List<double> _x = <double>[0, 0, 0, 0];
  List<double> _p = <double>[
    100,
    0,
    0,
    0,
    0,
    100,
    0,
    0,
    0,
    0,
    100,
    0,
    0,
    0,
    0,
    100,
  ];
  static const double _qPos = 0.5;
  static const double _qVel = 1.0;
  static const double _rGps = 9.0;
  bool _initialized = false;

  List<double> _matMul(List<double> a, List<double> b) {
    final c = List<double>.filled(16, 0);
    for (int i = 0; i < 4; i++) {
      for (int j = 0; j < 4; j++) {
        for (int k = 0; k < 4; k++) {
          c[i * 4 + j] += a[i * 4 + k] * b[k * 4 + j];
        }
      }
    }
    return c;
  }

  List<double> _matAdd(List<double> a, List<double> b) =>
      List.generate(16, (i) => a[i] + b[i]);
  List<double> _matSub(List<double> a, List<double> b) =>
      List.generate(16, (i) => a[i] - b[i]);
  List<double> _transpose(List<double> a) {
    final t = List<double>.filled(16, 0);
    for (int i = 0; i < 4; i++) {
      for (int j = 0; j < 4; j++) {
        t[j * 4 + i] = a[i * 4 + j];
      }
    }
    return t;
  }

  List<double> _inverse(List<double> m) {
    final a = List<double>.from(m);
    final inv = List<double>.filled(16, 0);
    for (int i = 0; i < 4; i++) {
      inv[i * 4 + i] = 1;
    }
    for (int col = 0; col < 4; col++) {
      int pivot = col;
      for (int row = col + 1; row < 4; row++) {
        if (a[row * 4 + col].abs() > a[pivot * 4 + col].abs()) pivot = row;
      }
      for (int j = 0; j < 4; j++) {
        double tmp = a[col * 4 + j];
        a[col * 4 + j] = a[pivot * 4 + j];
        a[pivot * 4 + j] = tmp;
        tmp = inv[col * 4 + j];
        inv[col * 4 + j] = inv[pivot * 4 + j];
        inv[pivot * 4 + j] = tmp;
      }
      final scale = a[col * 4 + col];
      if (scale.abs() < 1e-12) continue;
      for (int j = 0; j < 4; j++) {
        a[col * 4 + j] /= scale;
        inv[col * 4 + j] /= scale;
      }
      for (int row = 0; row < 4; row++) {
        if (row == col) continue;
        final factor = a[row * 4 + col];
        for (int j = 0; j < 4; j++) {
          a[row * 4 + j] -= factor * a[col * 4 + j];
          inv[row * 4 + j] -= factor * inv[col * 4 + j];
        }
      }
    }
    return inv;
  }

  double _lat0 = 0, _lng0 = 0;
  static const double _earthR = 6378137.0;

  // Converts geographic lat, lng to Cartesian x, y (in meters) relative to origin
  List<double> _toCartesian(double lat, double lng) {
    final lat0Rad = _lat0 * math.pi / 180.0;
    final dLat = (lat - _lat0) * math.pi / 180.0;
    final dLng = (lng - _lng0) * math.pi / 180.0;
    final x = _earthR * dLng * math.cos(lat0Rad);
    final y = _earthR * dLat;
    return <double>[x, y];
  }

  // Converts Cartesian x, y (in meters) relative to origin back to geographic lat, lng
  LatLng _toGeographic(double x, double y) {
    final lat0Rad = _lat0 * math.pi / 180.0;
    final dLat = y / _earthR;
    final dLng = x / (_earthR * math.cos(lat0Rad));
    return LatLng(
      _lat0 + dLat * 180.0 / math.pi,
      _lng0 + dLng * 180.0 / math.pi,
    );
  }

  void update(double lat, double lng, double dt) {
    if (!_initialized) {
      _lat0 = lat;
      _lng0 = lng;
      _x = <double>[0, 0, 0, 0];
      _initialized = true;
      return;
    }

    final cart = _toCartesian(lat, lng);
    final cx = cart[0];
    final cy = cart[1];
    final F = <double>[
      1.0,
      0.0,
      dt,
      0.0,
      0.0,
      1.0,
      0.0,
      dt,
      0.0,
      0.0,
      1.0,
      0.0,
      0.0,
      0.0,
      0.0,
      1.0,
    ];
    final dt2 = dt * dt;
    final dt3 = dt2 * dt;
    final dt4 = dt2 * dt2;

    final Q = <double>[
      dt4 / 4 * _qPos,
      0,
      dt3 / 2 * _qPos,
      0,
      0,
      dt4 / 4 * _qPos,
      0,
      dt3 / 2 * _qPos,
      dt3 / 2 * _qPos,
      0,
      dt2 * _qVel,
      0,
      0,
      dt3 / 2 * _qPos,
      0,
      dt2 * _qVel,
    ];
    final xp = <double>[
      F[0] * _x[0] + F[2] * _x[2],
      F[5] * _x[1] + F[7] * _x[3],
      _x[2],
      _x[3],
    ];
    final pp = _matAdd(_matMul(_matMul(F, _p), _transpose(F)), Q);
    final H = <double>[
      1.0,
      0.0,
      0.0,
      0.0,
      0.0,
      1.0,
      0.0,
      0.0,
      0.0,
      0.0,
      0.0,
      0.0,
      0.0,
      0.0,
      0.0,
      0.0,
    ];
    final R = <double>[_rGps, 0, 0, 0, 0, _rGps, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    final S = _matAdd(_matMul(_matMul(H, pp), _transpose(H)), R);
    final K = _matMul(_matMul(pp, _transpose(H)), _inverse(S));
    final y = <double>[cx - xp[0], cy - xp[1], 0.0, 0.0];
    _x = <double>[
      xp[0] + K[0] * y[0] + K[1] * y[1],
      xp[1] + K[4] * y[0] + K[5] * y[1],
      xp[2] + K[8] * y[0] + K[9] * y[1],
      xp[3] + K[12] * y[0] + K[13] * y[1],
    ];
    final I = <double>[1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0];
    _p = _matMul(_matSub(I, _matMul(K, H)), pp);
  }

  List<LatLng> forecast(int steps, double dt) {
    if (!_initialized) return [];
    var state = List<double>.from(_x);
    final result = <LatLng>[];
    for (int k = 0; k < steps; k++) {
      state = <double>[
        state[0] + state[2] * dt,
        state[1] + state[3] * dt,
        state[2],
        state[3],
      ];
      result.add(_toGeographic(state[0], state[1]));
    }
    return result;
  }

  LatLng get position =>
      _initialized ? _toGeographic(_x[0], _x[1]) : const LatLng(0, 0);
  bool get ready => _initialized;
}

// ══════════════════════════════════════════════════════════════════════════
// APP
// ══════════════════════════════════════════════════════════════════════════
class IoTMobileApp extends StatelessWidget {
  const IoTMobileApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'IOT dashboard',
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: C.bg,
      fontFamily: 'Manrope',
      textTheme: const TextTheme(
        displayLarge: TextStyle(fontFamily: 'Manrope', color: C.textPrimary),
        bodyMedium: TextStyle(fontFamily: 'Manrope', color: C.textSecondary),
      ),
    ),
    home: const SensorDashboard(),
  );
}

// ══════════════════════════════════════════════════════════════════════════
// DASHBOARD
// ══════════════════════════════════════════════════════════════════════════
class SensorDashboard extends StatefulWidget {
  const SensorDashboard({super.key});
  @override
  State<SensorDashboard> createState() => _SensorDashboardState();
}

class _SensorDashboardState extends State<SensorDashboard>
    with TickerProviderStateMixin {
  String status = 'INITIALIZING';
  bool isConnected = false;
  final speed = ValueNotifier<double>(0.0);
  final pitch = ValueNotifier<double>(0.0);
  final roll = ValueNotifier<double>(0.0);
  final yaw = ValueNotifier<double>(0.0);
  final ax = ValueNotifier<double>(0.0);
  final ay = ValueNotifier<double>(0.0);
  final az = ValueNotifier<double>(0.0);
  final lat = ValueNotifier<double>(23.2156);
  final lng = ValueNotifier<double>(72.6369);
  String cam1 = '', cam2 = '', cam3 = '';
  bool gpsReceived = false;
  DateTime _lastGpsTime = DateTime.now();
  final ValueNotifier<Queue<SensorLog>> _logs = ValueNotifier(
    Queue<SensorLog>(),
  );
  static const int _maxGraph = 60;
  int _tab = 0;
  final MapController _mapController = MapController();
  final Queue<LatLng> _gpsTrail = Queue<LatLng>();
  final HoltForecaster _fSpeed = HoltForecaster(alpha: 0.3, beta: 0.1);
  final HoltForecaster _fPitch = HoltForecaster(
    alpha: 0.3,
    beta: 0.1,
    isAngular: true,
  );
  final HoltForecaster _fRoll = HoltForecaster(
    alpha: 0.3,
    beta: 0.1,
    isAngular: true,
  );
  final HoltForecaster _fYaw = HoltForecaster(
    alpha: 0.3,
    beta: 0.1,
    isAngular: true,
  );
  final HoltForecaster _fAx = HoltForecaster(alpha: 0.4, beta: 0.05);
  final HoltForecaster _fAy = HoltForecaster(alpha: 0.4, beta: 0.05);
  final HoltForecaster _fAz = HoltForecaster(alpha: 0.4, beta: 0.05);
  final KalmanGPS _kalmanGPS = KalmanGPS();
  List<LatLng> _gpsForecast = [];
  bool _anomalySpeed = false,
      _anomalyPitch = false,
      _anomalyRoll = false,
      _anomalyYaw = false;
  bool _anomalyAx = false, _anomalyAy = false, _anomalyAz = false;
  bool _cameraOn = false;
  int _selectedCamera = 0;
  bool _isReconnecting = false;
  DateTime _lastConnectionToggleAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _connectionToggleCooldown = Duration(seconds: 1);

  final Map<String, String> _mdnsCache = {};

  Future<void> _updateCameraUrl(int camIndex, String rawUrl) async {
    if (rawUrl.isEmpty) {
      _setCamState(camIndex, '');
      return;
    }

    if (!rawUrl.contains('.local')) {
      _setCamState(camIndex, rawUrl);
      return;
    }

    if (_mdnsCache.containsKey(rawUrl)) {
      _setCamState(camIndex, _mdnsCache[rawUrl]!);
      return;
    }

    try {
      final uri = Uri.parse(rawUrl);
      final host = uri.host;
      if (host.endsWith('.local')) {
        final client = MDnsClient();
        await client.start();
        String? resolvedIp;
        await for (final IPAddressResourceRecord ptr
            in client.lookup<IPAddressResourceRecord>(
              ResourceRecordQuery.addressIPv4(host),
            )) {
          resolvedIp = ptr.address.address;
          break; // Use the first resolved IP
        }
        client.stop();

        if (resolvedIp != null) {
          final resolvedUrl = rawUrl.replaceFirst(host, resolvedIp);
          _mdnsCache[rawUrl] = resolvedUrl;
          if (mounted) _setCamState(camIndex, resolvedUrl);
          return;
        }
      }
    } catch (e) {
      debugPrint('mDNS resolution failed for $rawUrl: $e');
    }

    // Fallback original url if resolution fails
    _setCamState(camIndex, rawUrl);
  }

  void _setCamState(int index, String url) {
    if (!mounted) return;
    setState(() {
      if (index == 1) cam1 = url;
      if (index == 2) cam2 = url;
      if (index == 3) cam3 = url;
    });
  }

  MqttServerClient? client;
  late AnimationController _pulse;
  late Animation<double> _pulseAnim;
  late AnimationController _scanAnim;
  static const int _forecastSteps = 10;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(
      begin: 0.3,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut));
    _scanAnim = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
    _initMqtt();
  }

  @override
  void dispose() {
    _pulse.dispose();
    _scanAnim.dispose();
    speed.dispose();
    pitch.dispose();
    roll.dispose();
    yaw.dispose();
    ax.dispose();
    ay.dispose();
    az.dispose();
    lat.dispose();
    lng.dispose();
    _logs.dispose();
    client?.disconnect();
    super.dispose();
  }

  Future<void> _startCamera() async {
    if (mounted) {
      setState(() {
        _cameraOn = true;
      });
      final activeUrl = [cam1, cam2, cam3][_selectedCamera];
      debugPrint('Camera started. Selected camera: $_selectedCamera');
      debugPrint('Camera URL: $activeUrl');
    }
  }

  Future<void> _stopCamera() async {
    if (mounted) {
      setState(() {
        _cameraOn = false;
      });
    }
  }

  Future<void> _switchCamera() async {
    if (mounted) {
      setState(() {
        _selectedCamera = (_selectedCamera + 1) % 3;
      });
      // Trigger a rebuild to retry the stream
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) {
        setState(() {});
      }
    }
  }

  Future<void> _initMqtt() async {
    try {
      client = MqttServerClient.withPort(
        'broker.hivemq.com',
        'iot_dash_${DateTime.now().millisecondsSinceEpoch}',
        1883,
      );
      client!.keepAlivePeriod = 30;
      client!.connectTimeoutPeriod = 10000;
      client!.logging(on: false);
      client!.onConnected = () {
        if (mounted) {
          setState(() {
            status = 'LIVE';
            isConnected = true;
          });
        }
      };
      client!.onDisconnected = () {
        if (mounted) {
          setState(() {
            status = 'OFFLINE';
            isConnected = false;
          });
        }
      };
      client!.connectionMessage = MqttConnectMessage()
          .withClientIdentifier(
            'iot_dash_${DateTime.now().millisecondsSinceEpoch}',
          )
          .startClean()
          .withWillQos(MqttQos.atMostOnce);
      await client!.connect();
      if (client!.connectionStatus!.state == MqttConnectionState.connected) {
        client!.subscribe('myproject/sensors/all', MqttQos.atMostOnce);
        client!.updates?.listen((msgs) {
          final msg = msgs[0].payload as MqttPublishMessage;
          final raw = MqttPublishPayload.bytesToStringAsString(
            msg.payload.message,
          );
          try {
            final d = jsonDecode(raw);
            if (!mounted) return;

            final gpsObj = d['gps'] as Map<String, dynamic>? ?? {};
            final newLat = (gpsObj['lat'] as num?)?.toDouble() ?? lat.value;
            final newLng = (gpsObj['lng'] as num?)?.toDouble() ?? lng.value;
            final newSpeed = (gpsObj['speed'] as num?)?.toDouble() ?? 0.0;

            final oriObj = d['orientation'] as Map<String, dynamic>? ?? {};
            final newPitch = (oriObj['pitch'] as num?)?.toDouble() ?? 0.0;
            final newRoll = (oriObj['roll'] as num?)?.toDouble() ?? 0.0;
            final newYaw = (oriObj['yaw'] as num?)?.toDouble() ?? 0.0;

            final accObj = d['acceleration'] as Map<String, dynamic>? ?? {};
            final newAx = (accObj['ax'] as num?)?.toDouble() ?? 0.0;
            final newAy = (accObj['ay'] as num?)?.toDouble() ?? 0.0;
            final newAz = (accObj['az'] as num?)?.toDouble() ?? 0.0;

            final camsObj = d['cameras'] as Map<String, dynamic>? ?? {};
            final newCam1 =
                (camsObj['cam1'] as Map<String, dynamic>?)?['url'] as String? ??
                '';
            final newCam2 =
                (camsObj['cam2'] as Map<String, dynamic>?)?['url'] as String? ??
                '';
            final newCam3 =
                (camsObj['cam3'] as Map<String, dynamic>?)?['url'] as String? ??
                '';

            _fSpeed.update(newSpeed);
            _fPitch.update(newPitch);
            _fRoll.update(newRoll);
            _fYaw.update(newYaw);
            _fAx.update(newAx);
            _fAy.update(newAy);
            _fAz.update(newAz);
            final now = DateTime.now();
            final dt = now.difference(_lastGpsTime).inMilliseconds / 1000.0;
            _kalmanGPS.update(newLat, newLng, dt.clamp(0.05, 5.0));
            _lastGpsTime = now;

            _updateCameraUrl(1, newCam1);
            _updateCameraUrl(2, newCam2);
            _updateCameraUrl(3, newCam3);

            speed.value = newSpeed;
            pitch.value = newPitch;
            roll.value = newRoll;
            yaw.value = newYaw;
            ax.value = newAx;
            ay.value = newAy;
            az.value = newAz;
            lat.value = newLat;
            lng.value = newLng;

            final currentLogs = Queue<SensorLog>.from(_logs.value);
            currentLogs.addLast(
              SensorLog(
                time: now,
                speed: newSpeed,
                pitch: newPitch,
                roll: newRoll,
                yaw: newYaw,
                ax: newAx,
                ay: newAy,
                az: newAz,
                lat: newLat,
                lng: newLng,
              ),
            );
            if (currentLogs.length > 200) currentLogs.removeFirst();
            _logs.value = currentLogs;

            if (mounted) {
              setState(() {
                gpsReceived = true;
                _anomalySpeed = _fSpeed.isAnomaly(newSpeed);
                _anomalyPitch = _fPitch.isAnomaly(newPitch);
                _anomalyRoll = _fRoll.isAnomaly(newRoll);
                _anomalyYaw = _fYaw.isAnomaly(newYaw);
                _anomalyAx = _fAx.isAnomaly(newAx);
                _anomalyAy = _fAy.isAnomaly(newAy);
                _anomalyAz = _fAz.isAnomaly(newAz);
                _gpsForecast = _kalmanGPS.forecast(
                  _forecastSteps,
                  dt.clamp(0.05, 5.0),
                );
                if (_gpsTrail.length >= 100) {
                  _gpsTrail.removeFirst();
                }
                _gpsTrail.addLast(LatLng(newLat, newLng));
              });
            }
          } catch (e) {
            debugPrint('JSON Error: $e');
          }
        });
      }
    } catch (e) {
      debugPrint('MQTT Error: $e');
      if (mounted) {
        setState(() {
          status = 'OFFLINE';
          isConnected = false;
        });
      }
    }
  }

  Future<void> _reconnectMqtt() async {
    if (_isReconnecting) return;
    debugPrint('Attempting to reconnect...');
    if (mounted) {
      setState(() {
        _isReconnecting = true;
        status = 'CONNECTING...';
        isConnected = false;
      });
    }
    try {
      client?.disconnect();
      await Future.delayed(const Duration(milliseconds: 500));
      await _initMqtt();
    } catch (e) {
      debugPrint('Reconnect Error: $e');
      if (mounted) {
        setState(() {
          status = 'OFFLINE';
          isConnected = false;
        });
      }
      _showSnack('Reconnection failed: $e', C.roseRed, C.roseRedBright);
    } finally {
      if (mounted) {
        setState(() {
          _isReconnecting = false;
        });
      }
    }
  }

  Future<void> _toggleMqttConnection() async {
    final now = DateTime.now();
    if (now.difference(_lastConnectionToggleAt) < _connectionToggleCooldown) {
      return;
    }
    _lastConnectionToggleAt = now;

    if (_isReconnecting) return;
    if (isConnected) {
      client?.disconnect();
      if (mounted) {
        setState(() {
          status = 'OFFLINE';
          isConnected = false;
        });
      }
      return;
    }
    await _reconnectMqtt();
  }

  Future<void> _exportCsv() async {
    if (_logs.value.isEmpty) {
      _showSnack('No data to export yet.', C.surfaceHigh, C.textSecondary);
      return;
    }
    try {
      const header =
          'timestamp,speed_kmh,pitch_deg,roll_deg,yaw_deg,accel_x,accel_y,accel_z,lat,lng\n';
      final rows = _logs.value.toList().map((l) => l.toCsv()).join('\n');

      final dir = await getApplicationDocumentsDirectory();
      final fileName =
          'sensor_log_${DateTime.now().millisecondsSinceEpoch}.csv';
      final file = File('${dir.path}/$fileName');
      await file.writeAsString(header + rows);

      if (!mounted) return;

      _showSnack(
        'Exported ${_logs.value.length} records to ${file.path}.',
        C.emeraldDim,
        C.emerald,
      );
    } catch (e) {
      if (!mounted) return;
      _showSnack('Export failed: $e', C.roseRed, C.roseRedBright);
    }
  }

  void _showSnack(String msg, Color bg, Color fg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: bg,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        content: Text(
          msg,
          style: TextStyle(
            color: fg,
            fontFamily: 'JetBrains Mono',
            fontSize: 11,
          ),
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════
  // BUILD
  // ══════════════════════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            Expanded(
              child: IndexedStack(
                index: _tab,
                children: [
                  _buildDashTab(),
                  _buildGraphTab(),
                  _buildForecastTab(),
                  _buildLogTab(),
                ],
              ),
            ),
            _buildBottomNav(),
          ],
        ),
      ),
    );
  }

  // ── TOP BAR ────────────────────────────────────────────────────────
  Widget _buildTopBar() {
    return Container(
      color: C.surface,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Row(
        children: [
          // Brand name
          const Text(
            'IOT dashboard',
            style: TextStyle(
              fontFamily: 'Manrope',
              color: C.emerald,
              fontSize: 16,
              fontWeight: FontWeight.w800,
              letterSpacing: 3.0,
            ),
          ),
          const Spacer(),
          // Connection status pill
          AnimatedBuilder(
            animation: _pulseAnim,
            builder: (_, _) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleMqttConnection,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: isConnected
                      ? C.emerald.withValues(alpha: 0.1 * _pulseAnim.value)
                      : C.roseRed.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isConnected
                        ? C.emerald.withValues(alpha: 0.4 * _pulseAnim.value)
                        : C.roseRedBright.withValues(alpha: 0.3),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isConnected ? C.emerald : C.roseRedBright,
                        boxShadow: isConnected
                            ? [
                                BoxShadow(
                                  color: C.emerald.withValues(
                                    alpha: 0.6 * _pulseAnim.value,
                                  ),
                                  blurRadius: 8,
                                  spreadRadius: 1,
                                ),
                              ]
                            : null,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _isReconnecting ? 'CONNECTING...' : status,
                      style: TextStyle(
                        color: isConnected ? C.emerald : C.roseRedBright,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.5,
                        fontFamily: 'JetBrains Mono',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),
    );
  }

  // ── BOTTOM NAV ─────────────────────────────────────────────────────
  Widget _buildBottomNav() {
    final tabs = [
      (Icons.grid_view_rounded, 'DASHBOARD'),
      (Icons.show_chart_rounded, 'GRAPHS'),
      (Icons.podcasts_rounded, 'FORECAST'),
      (Icons.bar_chart_rounded, 'LOGS'),
    ];
    return Container(
      color: C.surface,
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Row(
        children: List.generate(tabs.length, (i) {
          final active = _tab == i;
          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _tab = i),
              behavior: HitTestBehavior.opaque,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: active ? 40 : 0,
                    height: 2,
                    margin: const EdgeInsets.only(bottom: 6),
                    decoration: BoxDecoration(
                      color: active ? C.emerald : Colors.transparent,
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: active
                          ? C.emerald.withValues(alpha: 0.12)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      tabs[i].$1,
                      color: active ? C.emerald : C.textMuted,
                      size: 20,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    tabs[i].$2,
                    style: TextStyle(
                      color: active ? C.emerald : C.textMuted,
                      fontSize: 8,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                      fontFamily: 'Manrope',
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════
  // TAB 0 — DASHBOARD
  // ══════════════════════════════════════════════════════════════════
  Widget _buildDashTab() {
    final anyAnomaly =
        _anomalySpeed ||
        _anomalyPitch ||
        _anomalyRoll ||
        _anomalyYaw ||
        _anomalyAx ||
        _anomalyAy ||
        _anomalyAz;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Page header
          Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'SYSTEM TELEMETRY',
                    style: TextStyle(
                      fontFamily: 'Manrope',
                      color: C.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'LAST SYNC: ${DateTime.now().hour.toString().padLeft(2, '0')}:'
                    '${DateTime.now().minute.toString().padLeft(2, '0')}:'
                    '${DateTime.now().second.toString().padLeft(2, '0')} IST',
                    style: const TextStyle(
                      fontFamily: 'JetBrains Mono',
                      color: C.textMuted,
                      fontSize: 9,
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              if (anyAnomaly)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: C.roseRed.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: C.roseRedBright.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.warning_amber_rounded,
                        color: C.roseRedBright,
                        size: 11,
                      ),
                      const SizedBox(width: 5),
                      const Text(
                        'ANOMALY DETECTED',
                        style: TextStyle(
                          color: C.roseRedBright,
                          fontSize: 8,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.5,
                          fontFamily: 'Manrope',
                        ),
                      ),
                    ],
                  ),
                ),
              GestureDetector(
                onTap: _exportCsv,
                child: Container(
                  margin: const EdgeInsets.only(left: 8),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: C.surfaceHigh,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: C.ghostBorder),
                  ),
                  child: const Icon(
                    Icons.upload_rounded,
                    color: C.textSecondary,
                    size: 16,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // GPS DATA section
          _buildSectionHeader('GPS Data'),
          const SizedBox(height: 12),
          _buildVelocityHeroCard(),
          const SizedBox(height: 12),
          _buildGpsCard(),
          const SizedBox(height: 28),

          // ORIENTATION DATA section
          _buildSectionHeader('Orientation Data'),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildSimpleMetricCard(
                  'Pitch',
                  pitch.value.toStringAsFixed(1),
                  '°',
                  Icons.flight_rounded,
                  _anomalyPitch,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildSimpleMetricCard(
                  'Roll',
                  roll.value.toStringAsFixed(1),
                  '°',
                  Icons.loop_rounded,
                  _anomalyRoll,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildSimpleMetricCard(
                  'Yaw',
                  yaw.value.toStringAsFixed(1),
                  '°',
                  Icons.threesixty_rounded,
                  _anomalyYaw,
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),

          // ACCELERATION DATA section
          _buildSectionHeader('Acceleration Data'),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _buildAccelCard('Accel X', ax.value, _anomalyAx)),
              const SizedBox(width: 10),
              Expanded(child: _buildAccelCard('Accel Y', ay.value, _anomalyAy)),
              const SizedBox(width: 10),
              Expanded(child: _buildAccelCard('Accel Z', az.value, _anomalyAz)),
            ],
          ),
          const SizedBox(height: 28),

          // CAMERAS section
          _buildSectionHeader('Cameras'),
          const SizedBox(height: 12),
          _buildCameraCard(),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  // SPEED HERO CARD
  Widget _buildVelocityHeroCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: C.surfaceHigh,
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            C.surfaceHigh,
            _anomalySpeed
                ? C.roseRed.withValues(alpha: 0.12)
                : C.emerald.withValues(alpha: 0.04),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: (_anomalySpeed ? C.roseRedBright : C.emerald).withValues(
              alpha: 0.08,
            ),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Row(
                children: [
                  Icon(
                    Icons.speed_rounded,
                    color: _anomalySpeed ? C.roseRedBright : C.textMuted,
                    size: 13,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Speed',
                    style: TextStyle(
                      color: _anomalySpeed ? C.roseRedBright : C.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'Manrope',
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                speed.value.toStringAsFixed(1),
                style: TextStyle(
                  fontFamily: 'Manrope',
                  color: _anomalySpeed ? C.roseRedBright : C.textPrimary,
                  fontSize: 52,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -2,
                  height: 1,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 8, left: 6),
                child: Text(
                  'km/h',
                  style: TextStyle(
                    color: _anomalySpeed
                        ? C.roseRedBright.withValues(alpha: 0.6)
                        : C.textMuted,
                    fontSize: 14,
                    fontFamily: 'Manrope',
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // SIMPLE METRIC CARD (Pitch / Roll)
  Widget _buildSimpleMetricCard(
    String label,
    String value,
    String unit,
    IconData icon,
    bool anomaly,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: anomaly ? C.roseRed.withValues(alpha: 0.08) : C.surfaceHigh,
        borderRadius: BorderRadius.circular(14),
        border: anomaly
            ? Border.all(color: C.roseRedBright.withValues(alpha: 0.25))
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                color: anomaly ? C.roseRedBright : C.textMuted,
                size: 13,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: anomaly ? C.roseRedBright : C.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'Manrope',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                value,
                style: TextStyle(
                  fontFamily: 'Manrope',
                  color: anomaly ? C.roseRedBright : C.textPrimary,
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 4, left: 3),
                child: Text(
                  unit,
                  style: TextStyle(
                    color: anomaly
                        ? C.roseRedBright.withValues(alpha: 0.6)
                        : C.textMuted,
                    fontSize: 13,
                    fontFamily: 'Manrope',
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ACCEL CARD
  Widget _buildAccelCard(String label, double val, bool anomaly) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: anomaly ? C.roseRed.withValues(alpha: 0.08) : C.surfaceHigh,
        borderRadius: BorderRadius.circular(14),
        border: anomaly
            ? Border.all(color: C.roseRedBright.withValues(alpha: 0.25))
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                style: TextStyle(
                  color: anomaly ? C.roseRedBright : C.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'Manrope',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                val.toStringAsFixed(2),
                style: TextStyle(
                  fontFamily: 'JetBrains Mono',
                  color: anomaly ? C.roseRedBright : C.textPrimary,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 3, left: 4),
                child: Text(
                  'm/s²',
                  style: TextStyle(
                    color: anomaly
                        ? C.roseRedBright.withValues(alpha: 0.6)
                        : C.textMuted,
                    fontSize: 12,
                    fontFamily: 'Manrope',
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, {Widget? trailing}) {
    return Row(
      children: [
        Text(
          title,
          style: const TextStyle(
            fontFamily: 'Manrope',
            color: C.textPrimary,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        const Spacer(),
        ?trailing,
      ],
    );
  }

  // GPS CARD
  Widget _buildGpsCard() {
    return Container(
      decoration: BoxDecoration(
        color: C.surfaceHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Row(
              children: [
                const Icon(
                  Icons.my_location_rounded,
                  color: C.emerald,
                  size: 13,
                ),
                const SizedBox(width: 8),
                Text(
                  gpsReceived
                      ? '${lat.value.toStringAsFixed(4)}, ${lng.value.toStringAsFixed(4)}'
                      : 'AWAITING SIGNAL',
                  style: TextStyle(
                    color: gpsReceived ? C.emerald : C.textMuted,
                    fontSize: 11,
                    fontFamily: 'JetBrains Mono',
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
                const Spacer(),
                if (gpsReceived)
                  GestureDetector(
                    onTap: () {
                      _mapController.move(LatLng(lat.value, lng.value), 15.0);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: C.surfaceHighest,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: C.ghostBorder),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.my_location_rounded,
                            color: C.textSecondary,
                            size: 12,
                          ),
                          SizedBox(width: 5),
                          Text(
                            'RECENTER',
                            style: TextStyle(
                              color: C.textSecondary,
                              fontSize: 8,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.1,
                              fontFamily: 'Manrope',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          ClipRRect(
            borderRadius: const BorderRadius.only(
              bottomLeft: Radius.circular(16),
              bottomRight: Radius.circular(16),
            ),
            child: SizedBox(
              height: 280,
              child: FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: LatLng(lat.value, lng.value),
                  initialZoom: 15,
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.example.iot_app',
                  ),
                  MarkerLayer(
                    markers: _gpsTrail
                        .map(
                          (p) => Marker(
                            point: p,
                            width: 8,
                            height: 8,
                            child: Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: C.emerald.withValues(alpha: 0.2),
                                border: Border.all(
                                  color: C.emerald.withValues(alpha: 0.5),
                                  width: 1,
                                ),
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                  if (_gpsForecast.isNotEmpty)
                    PolylineLayer(
                      polylines: [
                        Polyline(
                          points: [
                            LatLng(lat.value, lng.value),
                            ..._gpsForecast,
                          ],
                          color: C.iceBlueBright.withValues(alpha: 0.6),
                          strokeWidth: 2.0,
                        ),
                      ],
                    ),
                  if (_gpsForecast.isNotEmpty)
                    MarkerLayer(
                      markers: _gpsForecast
                          .asMap()
                          .entries
                          .map(
                            (e) => Marker(
                              point: e.value,
                              width: 10,
                              height: 10,
                              child: Container(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: C.iceBlueBright.withValues(
                                    alpha: 0.7 - e.key * 0.05,
                                  ),
                                  border: Border.all(
                                    color: C.iceBlueBright,
                                    width: 0.5,
                                  ),
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: LatLng(lat.value, lng.value),
                        width: 40,
                        height: 40,
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: C.emerald.withValues(alpha: 0.2),
                            border: Border.all(color: C.emerald, width: 2),
                            boxShadow: [
                              BoxShadow(
                                color: C.emerald.withValues(alpha: 0.4),
                                blurRadius: 12,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.circle,
                            color: C.emerald,
                            size: 10,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          // Lat/Lng readout bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Text(
                  'LAT/LNG',
                  style: const TextStyle(
                    color: C.textMuted,
                    fontSize: 8,
                    letterSpacing: 2,
                    fontFamily: 'JetBrains Mono',
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '${lat.value.toStringAsFixed(4)} ${lng.value.toStringAsFixed(4)}',
                  style: const TextStyle(
                    color: C.emerald,
                    fontSize: 10,
                    fontFamily: 'JetBrains Mono',
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // CAMERA CARD
  Widget _buildCameraCard() {
    return Container(
      decoration: BoxDecoration(
        color: C.surfaceHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Row(
              children: [
                if (_cameraOn)
                  GestureDetector(
                    onTap: _switchCamera,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      margin: const EdgeInsets.only(right: 10),
                      decoration: BoxDecoration(
                        color: C.surfaceHighest,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: C.ghostBorder),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.flip_camera_ios_rounded,
                            color: C.textSecondary,
                            size: 12,
                          ),
                          SizedBox(width: 5),
                          Text(
                            'SWITCH',
                            style: TextStyle(
                              color: C.textSecondary,
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1,
                              fontFamily: 'Manrope',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                const Spacer(),
                GestureDetector(
                  onTap: _cameraOn ? _stopCamera : _startCamera,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: _cameraOn
                          ? C.roseRed.withValues(alpha: 0.12)
                          : C.emerald.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: _cameraOn
                            ? C.roseRedBright.withValues(alpha: 0.35)
                            : C.emerald.withValues(alpha: 0.35),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _cameraOn
                              ? Icons.stop_rounded
                              : Icons.play_arrow_rounded,
                          color: _cameraOn ? C.roseRedBright : C.emerald,
                          size: 14,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          _cameraOn ? 'STOP' : 'START',
                          style: TextStyle(
                            color: _cameraOn ? C.roseRedBright : C.emerald,
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.5,
                            fontFamily: 'Manrope',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          ClipRRect(
            borderRadius: const BorderRadius.only(
              bottomLeft: Radius.circular(16),
              bottomRight: Radius.circular(16),
            ),
            child: SizedBox(
              height: 280,
              width: double.infinity,
              child: _buildCameraPreview(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCameraPreview() {
    final activeUrl = [cam1, cam2, cam3][_selectedCamera];

    if (!_cameraOn) {
      return Container(
        color: C.surfaceLow,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: C.ghostBorder, width: 1),
                ),
                child: const Icon(
                  Icons.videocam_off_outlined,
                  color: C.textMuted,
                  size: 26,
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'OPTICAL FEED INACTIVE',
                style: TextStyle(
                  color: C.textMuted,
                  fontSize: 10,
                  letterSpacing: 2,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'Manrope',
                ),
              ),
              const SizedBox(height: 5),
              const Text(
                'Tap Start to connect to camera feeds',
                style: TextStyle(
                  color: C.textMuted,
                  fontSize: 10,
                  fontFamily: 'Manrope',
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (activeUrl.isEmpty) {
      return Container(
        color: C.surfaceLow,
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: C.emerald, strokeWidth: 1.5),
              SizedBox(height: 16),
              Text(
                'WAITING FOR STREAM URL...',
                style: TextStyle(
                  color: C.textMuted,
                  fontSize: 9,
                  letterSpacing: 2,
                  fontFamily: 'JetBrains Mono',
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        SizedBox(
          width: double.infinity,
          height: double.infinity,
          child: MjpegView(
            uri: activeUrl,
            fit: BoxFit.cover,
            onError: (error, stackTrace) {
              debugPrint('Camera Error: $error for URL: $activeUrl');
            },
            errorWidget: (context) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'STREAM ERROR',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: C.roseRedBright,
                        fontSize: 10,
                        fontFamily: 'JetBrains Mono',
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      activeUrl,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: C.textMuted,
                        fontSize: 9,
                        fontFamily: 'JetBrains Mono',
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        Positioned.fill(
          child: CustomPaint(painter: _ObsidianViewfinderPainter()),
        ),
        // Bottom left overlay
        Positioned(
          bottom: 12,
          left: 14,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'ESP32_CAM_0${_selectedCamera + 1} // ACTIVE',
                style: const TextStyle(
                  color: C.emerald,
                  fontSize: 9,
                  fontFamily: 'JetBrains Mono',
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Text(
                'MJPEG STREAM',
                style: TextStyle(
                  color: C.textMuted,
                  fontSize: 9,
                  fontFamily: 'JetBrains Mono',
                ),
              ),
            ],
          ),
        ),
        // Top right status
        Positioned(
          top: 10,
          right: 14,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text(
              'LIVE',
              style: TextStyle(
                color: C.textMuted,
                fontSize: 8,
                fontFamily: 'JetBrains Mono',
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════════════
  // TAB 1 — GRAPHS (Performance Data)
  // ══════════════════════════════════════════════════════════════════
  Widget _buildGraphTab() {
    final listLogs = _logs.value.toList(growable: false);
    final graphLogs = listLogs.length > _maxGraph
        ? listLogs.sublist(listLogs.length - _maxGraph)
        : listLogs;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Performance Data',
            style: TextStyle(
              fontFamily: 'Manrope',
              color: C.textPrimary,
              fontSize: 26,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 24),

          // Speed Profile
          _buildNamedChart(
            title: 'Speed',
            subtitle: '',
            currentValue: speed.value.toStringAsFixed(1),
            logs: graphLogs,
            getValue: (l) => l.speed,
            forecaster: _fSpeed,
            color: C.emerald,
            yMin: 0,
            legendA: 'Nominal Speed',
            legendB: '95% Conf.',
            anomalyLabel: 'Delta Spike',
            hasAnomaly: _anomalySpeed,
          ),
          const SizedBox(height: 16),

          // Attitude Dynamics
          _buildNamedTripleChart(
            title: 'Orientation',
            subtitle: '',
            logs: graphLogs,
            getA: (l) => l.pitch,
            getB: (l) => l.roll,
            getC: (l) => l.yaw,
            fA: _fPitch,
            fB: _fRoll,
            fC: _fYaw,
            colorA: C.emerald,
            colorB: C.iceBlueBright,
            colorC: C.amber,
            labelA: 'Pitch (Y)',
            labelB: 'Roll (X)',
            labelC: 'Yaw (Z)',
            hasAnomaly: _anomalyPitch || _anomalyRoll || _anomalyYaw,
          ),
          const SizedBox(height: 16),

          // Linear Accel
          _buildNamedTripleChart(
            title: 'Acceleration',
            subtitle: '',
            logs: graphLogs,
            getA: (l) => l.ax,
            getB: (l) => l.ay,
            getC: (l) => l.az,
            fA: _fAx,
            fB: _fAy,
            fC: _fAz,
            colorA: C.emerald,
            colorB: C.iceBlueBright,
            colorC: C.amber,
            labelA: 'ACC_X',
            labelB: 'ACC_Y',
            labelC: 'ACC_Z',
            hasAnomaly: _anomalyAx || _anomalyAy || _anomalyAz,
            alertLabel: 'VIBE ALERT',
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildNamedChart({
    required String title,
    required String subtitle,
    required String currentValue,
    required List<SensorLog> logs,
    required double Function(SensorLog) getValue,
    required HoltForecaster forecaster,
    required Color color,
    double yMin = 0,
    required String legendA,
    required String legendB,
    required String anomalyLabel,
    required bool hasAnomaly,
  }) {
    if (logs.isEmpty) return _obsidianEmptyChart(title, subtitle);
    final values = logs.map(getValue).toList();
    final forecast = forecaster.ready
        ? forecaster.forecast(_forecastSteps)
        : <double>[];
    final allVals = [...values, ...forecast];
    final maxV = allVals.reduce(math.max) + 1;
    final minV = math.min(yMin, allVals.reduce(math.min) - 1);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: C.surfaceHigh,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: hasAnomaly
                ? C.roseRedBright.withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.3),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontFamily: 'Manrope',
                      color: C.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: C.textMuted,
                      fontSize: 9,
                      fontFamily: 'JetBrains Mono',
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: color,
                      boxShadow: [
                        BoxShadow(
                          color: color.withValues(alpha: 0.5),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    currentValue,
                    style: TextStyle(
                      color: color,
                      fontSize: 14,
                      fontFamily: 'JetBrains Mono',
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 150,
            width: double.infinity,
            child: CustomPaint(
              painter: _ObsidianForecastPainter(
                actual: values,
                forecast: forecast,
                anomalyFlags: logs
                    .map((l) => forecaster.isAnomaly(getValue(l)))
                    .toList(),
                stdDev: forecaster.stdDev,
                color: color,
                minY: minV,
                maxY: maxV,
              ),
            ),
          ),
          const SizedBox(height: 14),
          // Y-axis labels
          Row(
            children: [
              Text(
                maxV.toStringAsFixed(0),
                style: const TextStyle(
                  color: C.textMuted,
                  fontSize: 8,
                  fontFamily: 'JetBrains Mono',
                ),
              ),
              const Spacer(),
              Text(
                ((maxV + minV) / 2).toStringAsFixed(0),
                style: const TextStyle(
                  color: C.textMuted,
                  fontSize: 8,
                  fontFamily: 'JetBrains Mono',
                ),
              ),
              const Spacer(),
              Text(
                '0',
                style: const TextStyle(
                  color: C.textMuted,
                  fontSize: 8,
                  fontFamily: 'JetBrains Mono',
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Legend
          Row(
            children: [
              _obsLegendItem(color, legendA, solid: true),
              const SizedBox(width: 16),
              _obsLegendBand(color, legendB),
              const SizedBox(width: 16),
              _obsLegendDot(C.roseRedBright, anomalyLabel),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNamedTripleChart({
    required String title,
    required String subtitle,
    required List<SensorLog> logs,
    required double Function(SensorLog) getA,
    required double Function(SensorLog) getB,
    required double Function(SensorLog) getC,
    required HoltForecaster fA,
    required HoltForecaster fB,
    required HoltForecaster fC,
    required Color colorA,
    required Color colorB,
    required Color colorC,
    required String labelA,
    required String labelB,
    required String labelC,
    required bool hasAnomaly,
    String? alertLabel,
  }) {
    if (logs.isEmpty) return _obsidianEmptyChart(title, subtitle);
    final valA = logs.map(getA).toList();
    final valB = logs.map(getB).toList();
    final valC = logs.map(getC).toList();
    final foreA = fA.ready ? fA.forecast(_forecastSteps) : <double>[];
    final foreB = fB.ready ? fB.forecast(_forecastSteps) : <double>[];
    final foreC = fC.ready ? fC.forecast(_forecastSteps) : <double>[];

    final all = [...valA, ...valB, ...valC, ...foreA, ...foreB, ...foreC];
    final maxV = all.reduce(math.max) + 1;
    final minV = all.reduce(math.min) - 1;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: C.surfaceHigh,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: hasAnomaly
                ? C.roseRedBright.withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.3),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontFamily: 'Manrope',
                      color: C.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: C.textMuted,
                      fontSize: 9,
                      fontFamily: 'JetBrains Mono',
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              if (alertLabel != null && hasAnomaly)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: C.roseRed.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: C.roseRedBright.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.warning_amber_rounded,
                        color: C.roseRedBright,
                        size: 10,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        alertLabel,
                        style: const TextStyle(
                          color: C.roseRedBright,
                          fontSize: 8,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2,
                          fontFamily: 'Manrope',
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 150,
            width: double.infinity,
            child: CustomPaint(
              painter: _ObsidianTriplePainter(
                actualA: valA,
                actualB: valB,
                actualC: valC,
                forecastA: foreA,
                forecastB: foreB,
                forecastC: foreC,
                anomalyA: logs.map((l) => fA.isAnomaly(getA(l))).toList(),
                anomalyB: logs.map((l) => fB.isAnomaly(getB(l))).toList(),
                anomalyC: logs.map((l) => fC.isAnomaly(getC(l))).toList(),
                colorA: colorA,
                colorB: colorB,
                colorC: colorC,
                minY: minV,
                maxY: maxV,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Text(
                maxV.toStringAsFixed(1),
                style: const TextStyle(
                  color: C.textMuted,
                  fontSize: 8,
                  fontFamily: 'JetBrains Mono',
                ),
              ),
              const Spacer(),
              Text(
                minV.toStringAsFixed(1),
                style: const TextStyle(
                  color: C.textMuted,
                  fontSize: 8,
                  fontFamily: 'JetBrains Mono',
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 14,
            runSpacing: 8,
            children: [
              _obsLegendItem(colorA, labelA, solid: true),
              _obsLegendItem(colorB, labelB, solid: true),
              _obsLegendItem(colorC, labelC, solid: true),
            ],
          ),
        ],
      ),
    );
  }

  Widget _obsidianEmptyChart(String title, String subtitle) {
    return Container(
      height: 200,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: C.surfaceHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontFamily: 'Manrope',
              color: C.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            subtitle,
            style: const TextStyle(
              color: C.textMuted,
              fontSize: 9,
              fontFamily: 'JetBrains Mono',
            ),
          ),
          const Expanded(
            child: Center(
              child: Text(
                'AWAITING TELEMETRY...',
                style: TextStyle(
                  color: C.textMuted,
                  fontSize: 10,
                  fontFamily: 'JetBrains Mono',
                  letterSpacing: 2,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _obsLegendItem(
    Color color,
    String label, {
    bool solid = false,
    bool dashed = false,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 20,
          height: 10,
          child: CustomPaint(
            painter: _ObsLegendLine(color: color, dashed: dashed),
          ),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            color: color.withValues(alpha: 0.8),
            fontSize: 9,
            fontFamily: 'Manrope',
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }

  Widget _obsLegendBand(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 16,
          height: 8,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(2),
            border: Border.all(color: color.withValues(alpha: 0.3), width: 0.5),
          ),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            color: color.withValues(alpha: 0.7),
            fontSize: 9,
            fontFamily: 'Manrope',
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _obsLegendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            color: color.withValues(alpha: 0.8),
            fontSize: 9,
            fontFamily: 'Manrope',
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════════════
  // TAB 2 — FORECAST (Prediction Engine)
  // ══════════════════════════════════════════════════════════════════

  // ── Small section label helper ────────────────────────────────────
  Widget _buildSectionLabel(String label) {
    return Row(
      children: [
        Container(
          width: 3,
          height: 14,
          decoration: BoxDecoration(
            color: C.emerald,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(
            color: C.textMuted,
            fontSize: 9,
            fontFamily: 'JetBrains Mono',
            fontWeight: FontWeight.w700,
            letterSpacing: 2,
          ),
        ),
      ],
    );
  }

  // ── Main forecast tab ─────────────────────────────────────────────
  Widget _buildForecastTab() {
    final ready = _fSpeed.ready;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Forecasting',
            style: TextStyle(
              fontFamily: 'Manrope',
              color: C.textPrimary,
              fontSize: 26,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 28),

          if (!ready) ...[
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: C.surfaceHigh,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(
                    color: C.emerald,
                    strokeWidth: 1.5,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '${5 - _logs.value.length > 0 ? 5 - _logs.value.length : 0} more readings needed to start forecasting',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: C.textMuted,
                      fontSize: 11,
                      fontFamily: 'JetBrains Mono',
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ),
            ),
          ] else ...[
            // ── 1. 10-step sensor forecast table ──────────────────────
            _buildSectionLabel('10-STEP SENSOR FORECAST'),
            const SizedBox(height: 10),
            _buildForecastTable(),
            const SizedBox(height: 24),

            // ── 2. Anomaly status per sensor ──────────────────────────
            _buildSectionLabel('ANOMALY STATUS  (Z-SCORE)'),
            const SizedBox(height: 10),
            _buildZScorePanel(),
            const SizedBox(height: 24),

            // ── 3. GPS Kalman forecast ─────────────────────────────────
            if (_kalmanGPS.ready) ...[
              _buildSectionLabel('GPS TRAJECTORY Estimation'),
              const SizedBox(height: 10),
              _buildVectorProjection(),
              const SizedBox(height: 24),
            ],

            // ── 4. Model stats ─────────────────────────────────────────
            _buildSectionLabel('MODEL STATISTICS'),
            const SizedBox(height: 10),
            _buildModelStats(),
            const SizedBox(height: 20),
          ],
        ],
      ),
    );
  }

  // ── 1. Forecast table — all sensors, t+1 to t+10 ─────────────────
  Widget _buildForecastTable() {
    final fSpd = _fSpeed.forecast(_forecastSteps);
    final fPit = _fPitch.forecast(_forecastSteps);
    final fRol = _fRoll.forecast(_forecastSteps);
    final fYaw = _fYaw.forecast(_forecastSteps);
    final fAx = _fAx.forecast(_forecastSteps);
    final fAy = _fAy.forecast(_forecastSteps);
    final fAz = _fAz.forecast(_forecastSteps);

    // Column header helper
    Widget hdr(String t, Color c) => Expanded(
      child: Text(
        t,
        style: TextStyle(
          color: c,
          fontSize: 8,
          fontFamily: 'JetBrains Mono',
          fontWeight: FontWeight.w700,
          letterSpacing: 1,
        ),
        textAlign: TextAlign.right,
      ),
    );

    // Cell helper — opacity fades with step distance
    Widget cell(String v, Color c, double opacity) => Expanded(
      child: Text(
        v,
        style: TextStyle(
          color: c.withValues(alpha: opacity),
          fontSize: 9.5,
          fontFamily: 'JetBrains Mono',
          fontWeight: FontWeight.w600,
        ),
        textAlign: TextAlign.right,
      ),
    );

    return Container(
      decoration: BoxDecoration(
        color: C.surfaceHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          // Header row
          Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
            decoration: BoxDecoration(
              color: C.surfaceHighest,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(14),
                topRight: Radius.circular(14),
              ),
            ),
            child: Row(
              children: [
                // Step label column
                SizedBox(
                  width: 38,
                  child: Text(
                    'STEP',
                    style: const TextStyle(
                      color: C.textMuted,
                      fontSize: 8,
                      fontFamily: 'JetBrains Mono',
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                    ),
                  ),
                ),
                hdr('SPD\nkm/h', C.emerald),
                hdr('PCH\n°', C.iceBlueBright),
                hdr('ROL\n°', C.iceBlueBright),
                hdr('YAW\n°', C.amber),
                hdr('AX\ng', C.emerald),
                hdr('AY\ng', C.iceBlueBright),
                hdr('AZ\ng', C.amber),
              ],
            ),
          ),

          // Data rows
          ...List.generate(_forecastSteps, (i) {
            final conf = math.max(0.15, 1.0 - i * 0.085);
            final isEven = i % 2 == 0;
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: isEven
                    ? C.surfaceLow.withValues(alpha: 0.5)
                    : Colors.transparent,
                borderRadius: i == _forecastSteps - 1
                    ? const BorderRadius.only(
                        bottomLeft: Radius.circular(14),
                        bottomRight: Radius.circular(14),
                      )
                    : null,
              ),
              child: Row(
                children: [
                  // Step label
                  SizedBox(
                    width: 38,
                    child: Text(
                      't+${i + 1}',
                      style: TextStyle(
                        color: C.emerald.withValues(alpha: conf),
                        fontSize: 9,
                        fontFamily: 'JetBrains Mono',
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  cell(fSpd[i].toStringAsFixed(1), C.emerald, conf),
                  cell(fPit[i].toStringAsFixed(1), C.iceBlueBright, conf),
                  cell(fRol[i].toStringAsFixed(1), C.iceBlueBright, conf),
                  cell(fYaw[i].toStringAsFixed(1), C.amber, conf),
                  cell(fAx[i].toStringAsFixed(3), C.emerald, conf),
                  cell(fAy[i].toStringAsFixed(3), C.iceBlueBright, conf),
                  cell(fAz[i].toStringAsFixed(3), C.amber, conf),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  // ── 2. Z-score anomaly panel ──────────────────────────────────────
  Widget _buildZScorePanel() {
    // Build sensor data: name, current value, unit, forecaster, anomaly flag, color
    final sensors = [
      ('Speed', speed.value, 'km/h', _fSpeed, _anomalySpeed, C.emerald),
      ('Pitch', pitch.value, '°', _fPitch, _anomalyPitch, C.iceBlueBright),
      ('Roll', roll.value, '°', _fRoll, _anomalyRoll, C.iceBlueBright),
      ('Yaw', yaw.value, '°', _fYaw, _anomalyYaw, C.amber),
      ('Accel X', ax.value, 'm/s²', _fAx, _anomalyAx, C.emerald),
      ('Accel Y', ay.value, 'm/s²', _fAy, _anomalyAy, C.iceBlueBright),
      ('Accel Z', az.value, 'm/s²', _fAz, _anomalyAz, C.amber),
    ];

    return Container(
      decoration: BoxDecoration(
        color: C.surfaceHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: sensors.asMap().entries.map((entry) {
          final i = entry.key;
          final s = entry.value;
          final name = s.$1;
          final val = s.$2;
          final unit = s.$3;
          final fore = s.$4;
          final isAnom = s.$5;
          final color = s.$6;
          final z = fore.zScore(val);
          final isLast = i == sensors.length - 1;

          // Z-score bar: normalised -3..+3 → 0..1
          final barFraction = ((z + 3.0) / 6.0).clamp(0.0, 1.0);

          return Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            decoration: BoxDecoration(
              border: isLast
                  ? null
                  : Border(
                      bottom: BorderSide(
                        color: C.surfaceHighest.withValues(alpha: 0.5),
                      ),
                    ),
              borderRadius: isLast
                  ? const BorderRadius.only(
                      bottomLeft: Radius.circular(14),
                      bottomRight: Radius.circular(14),
                    )
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // Sensor name + current value
                    Text(
                      name,
                      style: TextStyle(
                        color: isAnom ? C.roseRedBright : color,
                        fontSize: 12,
                        fontFamily: 'Manrope',
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${val.toStringAsFixed(val.abs() < 10 ? 2 : 1)} $unit',
                      style: TextStyle(
                        color: C.textSecondary,
                        fontSize: 11,
                        fontFamily: 'JetBrains Mono',
                      ),
                    ),
                    const Spacer(),
                    // Z-score value
                    Text(
                      'z = ${z >= 0 ? '+' : ''}${z.toStringAsFixed(2)}',
                      style: TextStyle(
                        color: isAnom ? C.roseRedBright : C.textMuted,
                        fontSize: 11,
                        fontFamily: 'JetBrains Mono',
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 10),
                    // Status badge
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: isAnom
                            ? C.roseRed.withValues(alpha: 0.15)
                            : C.emerald.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: isAnom
                              ? C.roseRedBright.withValues(alpha: 0.4)
                              : C.emerald.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Text(
                        isAnom ? 'ANOMALY' : 'NOMINAL',
                        style: TextStyle(
                          color: isAnom ? C.roseRedBright : C.emerald,
                          fontSize: 8,
                          fontFamily: 'JetBrains Mono',
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                // Z-score bar
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: Stack(
                    children: [
                      // Track
                      Container(
                        height: 4,
                        decoration: BoxDecoration(
                          color: C.surfaceHighest,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      // Centre marker (z=0)
                      Positioned(
                        left: null,
                        right: null,
                        child: FractionallySizedBox(
                          widthFactor: 0.5,
                          child: Container(
                            height: 4,
                            decoration: BoxDecoration(
                              border: Border(
                                right: BorderSide(
                                  color: C.textMuted.withValues(alpha: 0.3),
                                  width: 1,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      // Fill
                      FractionallySizedBox(
                        widthFactor: barFraction,
                        child: Container(
                          height: 4,
                          decoration: BoxDecoration(
                            color: isAnom ? C.roseRedBright : color,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 3),
                // Range labels
                Row(
                  children: [
                    Text(
                      '−3σ',
                      style: TextStyle(
                        color: C.textMuted,
                        fontSize: 7,
                        fontFamily: 'JetBrains Mono',
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '0',
                      style: TextStyle(
                        color: C.textMuted,
                        fontSize: 7,
                        fontFamily: 'JetBrains Mono',
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '+3σ',
                      style: TextStyle(
                        color: C.textMuted,
                        fontSize: 7,
                        fontFamily: 'JetBrains Mono',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  // ── 3. GPS Kalman forecast ────────────────────────────────────────
  Widget _buildVectorProjection() {
    // Compute distances from current position
    double haversine(double lat1, double lng1, double lat2, double lng2) {
      const R = 6371000.0; // metres
      final dLat = (lat2 - lat1) * math.pi / 180;
      final dLng = (lng2 - lng1) * math.pi / 180;
      final a =
          math.sin(dLat / 2) * math.sin(dLat / 2) +
          math.cos(lat1 * math.pi / 180) *
              math.cos(lat2 * math.pi / 180) *
              math.sin(dLng / 2) *
              math.sin(dLng / 2);
      return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    }

    return Container(
      decoration: BoxDecoration(
        color: C.surfaceHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          // Mini trajectory visualisation
          ClipRRect(
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(14),
              topRight: Radius.circular(14),
            ),
            child: Container(
              height: 100,
              color: C.surfaceLow,
              child: CustomPaint(
                painter: _VectorProjectionPainter(forecast: _gpsForecast),
                size: const Size(double.infinity, 100),
              ),
            ),
          ),

          // Current position header
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
            child: Row(
              children: [
                const Icon(
                  Icons.my_location_rounded,
                  color: C.emerald,
                  size: 13,
                ),
                const SizedBox(width: 6),
                Text(
                  '${lat.value.toStringAsFixed(6)}°N  ${lng.value.toStringAsFixed(6)}°W',
                  style: const TextStyle(
                    color: C.emerald,
                    fontSize: 10,
                    fontFamily: 'JetBrains Mono',
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                const Text(
                  'CURRENT',
                  style: TextStyle(
                    color: C.textMuted,
                    fontSize: 8,
                    fontFamily: 'JetBrains Mono',
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),
          ),

          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 14),
            child: Divider(
              color: Color(0xFF2A2A2B),
              height: 16,
              thickness: 0.5,
            ),
          ),

          // Column headers
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
            child: Row(
              children: [
                SizedBox(
                  width: 38,
                  child: Text(
                    'STEP',
                    style: const TextStyle(
                      color: C.textMuted,
                      fontSize: 8,
                      fontFamily: 'JetBrains Mono',
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    'LATITUDE',
                    style: const TextStyle(
                      color: C.textMuted,
                      fontSize: 8,
                      fontFamily: 'JetBrains Mono',
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    'LONGITUDE',
                    style: const TextStyle(
                      color: C.textMuted,
                      fontSize: 8,
                      fontFamily: 'JetBrains Mono',
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                    ),
                  ),
                ),
                SizedBox(
                  width: 64,
                  child: Text(
                    'DIST',
                    style: const TextStyle(
                      color: C.textMuted,
                      fontSize: 8,
                      fontFamily: 'JetBrains Mono',
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                    ),
                    textAlign: TextAlign.right,
                  ),
                ),
                SizedBox(
                  width: 40,
                  child: Text(
                    'CONF',
                    style: const TextStyle(
                      color: C.textMuted,
                      fontSize: 8,
                      fontFamily: 'JetBrains Mono',
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                    ),
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          ),

          // Forecast rows
          ..._gpsForecast.asMap().entries.map((e) {
            final i = e.key;
            final pt = e.value;
            final conf = math.max(0.15, 1.0 - i * 0.085);
            final dist = haversine(
              lat.value,
              lng.value,
              pt.latitude,
              pt.longitude,
            );
            final isLast = i == _gpsForecast.length - 1;

            return Container(
              padding: const EdgeInsets.fromLTRB(14, 5, 14, 5),
              decoration: BoxDecoration(
                color: i % 2 == 0
                    ? C.surfaceLow.withValues(alpha: 0.4)
                    : Colors.transparent,
                borderRadius: isLast
                    ? const BorderRadius.only(
                        bottomLeft: Radius.circular(14),
                        bottomRight: Radius.circular(14),
                      )
                    : null,
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 38,
                    child: Text(
                      't+${i + 1}',
                      style: TextStyle(
                        color: C.iceBlueBright.withValues(alpha: conf),
                        fontSize: 9,
                        fontFamily: 'JetBrains Mono',
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      pt.latitude.toStringAsFixed(6),
                      style: TextStyle(
                        color: C.textSecondary.withValues(alpha: conf),
                        fontSize: 9.5,
                        fontFamily: 'JetBrains Mono',
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      pt.longitude.toStringAsFixed(6),
                      style: TextStyle(
                        color: C.textSecondary.withValues(alpha: conf),
                        fontSize: 9.5,
                        fontFamily: 'JetBrains Mono',
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 64,
                    child: Text(
                      dist < 1000
                          ? '${dist.toStringAsFixed(1)} m'
                          : '${(dist / 1000).toStringAsFixed(2)} km',
                      style: TextStyle(
                        color: C.emerald.withValues(alpha: conf),
                        fontSize: 9,
                        fontFamily: 'JetBrains Mono',
                        fontWeight: FontWeight.w600,
                      ),
                      textAlign: TextAlign.right,
                    ),
                  ),
                  SizedBox(
                    width: 40,
                    child: Text(
                      '${(conf * 100).toStringAsFixed(0)}%',
                      style: TextStyle(
                        color: C.textMuted.withValues(alpha: conf),
                        fontSize: 9,
                        fontFamily: 'JetBrains Mono',
                      ),
                      textAlign: TextAlign.right,
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  // ── 4. Model statistics ───────────────────────────────────────────
  Widget _buildModelStats() {
    final stats = [
      (
        'SPEED',
        'km/h',
        _fSpeed.mean,
        _fSpeed.stdDev,
        speed.value,
        _anomalySpeed,
        C.emerald,
      ),
      (
        'PITCH',
        '°',
        _fPitch.mean,
        _fPitch.stdDev,
        pitch.value,
        _anomalyPitch,
        C.iceBlueBright,
      ),
      (
        'ROLL',
        '°',
        _fRoll.mean,
        _fRoll.stdDev,
        roll.value,
        _anomalyRoll,
        C.iceBlueBright,
      ),
      ('YAW', '°', _fYaw.mean, _fYaw.stdDev, yaw.value, _anomalyYaw, C.amber),
      (
        'ACCEL X',
        'm/s²',
        _fAx.mean,
        _fAx.stdDev,
        ax.value,
        _anomalyAx,
        C.emerald,
      ),
      (
        'ACCEL Y',
        'm/s²',
        _fAy.mean,
        _fAy.stdDev,
        ay.value,
        _anomalyAy,
        C.iceBlueBright,
      ),
      (
        'ACCEL Z',
        'm/s²',
        _fAz.mean,
        _fAz.stdDev,
        az.value,
        _anomalyAz,
        C.amber,
      ),
    ];

    return Container(
      decoration: BoxDecoration(
        color: C.surfaceHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
            decoration: BoxDecoration(
              color: C.surfaceHighest,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(14),
                topRight: Radius.circular(14),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Text(
                    'SENSOR',
                    style: const TextStyle(
                      color: C.textMuted,
                      fontSize: 8,
                      fontFamily: 'JetBrains Mono',
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    'MEAN',
                    style: const TextStyle(
                      color: C.textMuted,
                      fontSize: 8,
                      fontFamily: 'JetBrains Mono',
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                    ),
                    textAlign: TextAlign.right,
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    'STD DEV',
                    style: const TextStyle(
                      color: C.textMuted,
                      fontSize: 8,
                      fontFamily: 'JetBrains Mono',
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                    ),
                    textAlign: TextAlign.right,
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    '95% CI',
                    style: const TextStyle(
                      color: C.textMuted,
                      fontSize: 8,
                      fontFamily: 'JetBrains Mono',
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                    ),
                    textAlign: TextAlign.right,
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    'CURRENT',
                    style: const TextStyle(
                      color: C.textMuted,
                      fontSize: 8,
                      fontFamily: 'JetBrains Mono',
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                    ),
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          ),

          // Rows
          ...stats.asMap().entries.map((entry) {
            final i = entry.key;
            final s = entry.value;
            final name = s.$1;
            final unit = s.$2;
            final mean = s.$3;
            final sd = s.$4;
            final cur = s.$5;
            final anom = s.$6;
            final col = s.$7;
            final ci = 1.96 * sd;
            final isLast = i == stats.length - 1;

            return Container(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
              decoration: BoxDecoration(
                color: i % 2 == 0
                    ? C.surfaceLow.withValues(alpha: 0.4)
                    : Colors.transparent,
                borderRadius: isLast
                    ? const BorderRadius.only(
                        bottomLeft: Radius.circular(14),
                        bottomRight: Radius.circular(14),
                      )
                    : null,
              ),
              child: Row(
                children: [
                  // Sensor name + unit
                  Expanded(
                    flex: 3,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: TextStyle(
                            color: col,
                            fontSize: 10,
                            fontFamily: 'Manrope',
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          unit,
                          style: TextStyle(
                            color: C.textMuted,
                            fontSize: 8,
                            fontFamily: 'JetBrains Mono',
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Mean
                  Expanded(
                    flex: 2,
                    child: Text(
                      mean.toStringAsFixed(2),
                      style: const TextStyle(
                        color: C.textSecondary,
                        fontSize: 10,
                        fontFamily: 'JetBrains Mono',
                      ),
                      textAlign: TextAlign.right,
                    ),
                  ),
                  // Std dev
                  Expanded(
                    flex: 2,
                    child: Text(
                      sd.toStringAsFixed(3),
                      style: const TextStyle(
                        color: C.textSecondary,
                        fontSize: 10,
                        fontFamily: 'JetBrains Mono',
                      ),
                      textAlign: TextAlign.right,
                    ),
                  ),
                  // 95% CI
                  Expanded(
                    flex: 2,
                    child: Text(
                      '±${ci.toStringAsFixed(3)}',
                      style: TextStyle(
                        color: col,
                        fontSize: 10,
                        fontFamily: 'JetBrains Mono',
                        fontWeight: FontWeight.w600,
                      ),
                      textAlign: TextAlign.right,
                    ),
                  ),
                  // Current vs mean indicator
                  Expanded(
                    flex: 2,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (anom)
                          const Icon(
                            Icons.warning_amber_rounded,
                            color: C.roseRedBright,
                            size: 11,
                          ),
                        const SizedBox(width: 3),
                        Text(
                          cur.abs() < 10
                              ? cur.toStringAsFixed(2)
                              : cur.toStringAsFixed(1),
                          style: TextStyle(
                            color: anom ? C.roseRedBright : C.textPrimary,
                            fontSize: 10,
                            fontFamily: 'JetBrains Mono',
                            fontWeight: FontWeight.w700,
                          ),
                          textAlign: TextAlign.right,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════
  // TAB 3 — LOGS (Telemetry Logs)
  // ══════════════════════════════════════════════════════════════════
  Widget _buildLogTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Telemetry Logs',
                    style: TextStyle(
                      fontFamily: 'Manrope',
                      color: C.textPrimary,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'Live high-frequency sensor readouts.',
                    style: TextStyle(
                      color: C.textSecondary,
                      fontSize: 12,
                      fontFamily: 'Manrope',
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Row(
                children: [
                  GestureDetector(
                    onTap: _exportCsv,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: C.surfaceHigh,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: C.ghostBorder),
                      ),
                      child: const Icon(
                        Icons.upload_rounded,
                        color: C.textSecondary,
                        size: 16,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => setState(() => _logs.value.clear()),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: C.surfaceHigh,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: C.ghostBorder),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.delete_outline_rounded,
                            color: C.textSecondary,
                            size: 14,
                          ),
                          SizedBox(width: 5),
                          Text(
                            'Clear Logs',
                            style: TextStyle(
                              color: C.textSecondary,
                              fontSize: 11,
                              fontFamily: 'Manrope',
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // Table header
        Container(
          color: C.surfaceLow,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Row(
            children: [
              _logH('TIMESTAMP', flex: 4),
              _logH('SPD', flex: 2),
              _logH('PCH', flex: 2),
              _logH('RLL', flex: 2),
              _logH('ACC', flex: 2),
            ],
          ),
        ),
        // Rows
        Expanded(
          child: _logs.value.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'NO TELEMETRY STREAM',
                        style: TextStyle(
                          color: C.textMuted,
                          fontSize: 11,
                          fontFamily: 'JetBrains Mono',
                          letterSpacing: 2,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: C.textMuted,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'STREAM INACTIVE',
                        style: TextStyle(
                          color: C.textMuted,
                          fontSize: 9,
                          fontFamily: 'JetBrains Mono',
                          letterSpacing: 1.5,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: _logs.value.length,
                  itemBuilder: (_, i) {
                    final l = _logs.value.elementAt(_logs.value.length - 1 - i);
                    final isAnomalyRow =
                        _fSpeed.isAnomaly(l.speed) ||
                        _fAx.isAnomaly(l.ax) ||
                        _fAy.isAnomaly(l.ay);
                    return Container(
                      color: isAnomalyRow ? C.anomalyRow : Colors.transparent,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          if (isAnomalyRow)
                            Container(
                              width: 2,
                              height: 30,
                              margin: const EdgeInsets.only(right: 6),
                              color: C.roseRedBright,
                            ),
                          Expanded(
                            flex: isAnomalyRow ? 0 : 4,
                            child: Container(),
                          ),
                          if (!isAnomalyRow)
                            _logC(
                              '${l.time.hour.toString().padLeft(2, '0')}:'
                              '${l.time.minute.toString().padLeft(2, '0')}:'
                              '${l.time.second.toString().padLeft(2, '0')}.'
                              '${(l.time.millisecond).toString().padLeft(3, '0')}',
                              flex: 4,
                              color: C.textMuted,
                            ),
                          if (isAnomalyRow)
                            Expanded(
                              flex: 4,
                              child: Text(
                                '${l.time.hour.toString().padLeft(2, '0')}:'
                                '${l.time.minute.toString().padLeft(2, '0')}:'
                                '${l.time.second.toString().padLeft(2, '0')}.'
                                '${l.time.millisecond.toString().padLeft(3, '0')}',
                                style: const TextStyle(
                                  color: C.textMuted,
                                  fontSize: 10,
                                  fontFamily: 'JetBrains Mono',
                                ),
                              ),
                            ),
                          _logC(
                            l.speed.toStringAsFixed(1),
                            flex: 2,
                            color: isAnomalyRow ? C.roseRedBright : C.emerald,
                          ),
                          _logC(
                            l.pitch.toStringAsFixed(2),
                            flex: 2,
                            color: isAnomalyRow
                                ? C.roseRedBright
                                : C.textSecondary,
                          ),
                          _logC(
                            l.roll.toStringAsFixed(2),
                            flex: 2,
                            color: _fAx.isAnomaly(l.ax)
                                ? C.roseRedBright
                                : C.iceBlueBright,
                          ),
                          _logC(
                            '${l.ax.toStringAsFixed(2)}G',
                            flex: 2,
                            color: isAnomalyRow
                                ? C.roseRedBright
                                : C.textSecondary,
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        // Stream status
        Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isConnected ? C.emerald : C.textMuted,
                  boxShadow: isConnected
                      ? [
                          BoxShadow(
                            color: C.emerald.withValues(alpha: 0.5),
                            blurRadius: 6,
                          ),
                        ]
                      : null,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                isConnected ? 'STREAM ACTIVE' : 'STREAM INACTIVE',
                style: TextStyle(
                  color: isConnected ? C.emerald : C.textMuted,
                  fontSize: 9,
                  fontFamily: 'JetBrains Mono',
                  letterSpacing: 1.5,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _logH(String t, {int flex = 1}) => Expanded(
    flex: flex,
    child: Text(
      t,
      style: const TextStyle(
        color: C.textMuted,
        fontSize: 9,
        fontFamily: 'JetBrains Mono',
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
      ),
    ),
  );

  Widget _logC(String t, {int flex = 1, Color color = C.textSecondary}) =>
      Expanded(
        flex: flex,
        child: Text(
          t,
          style: TextStyle(
            color: color,
            fontSize: 10,
            fontFamily: 'JetBrains Mono',
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}

// ══════════════════════════════════════════════════════════════════════════
// OBSIDIAN FORECAST PAINTER — single series
// ══════════════════════════════════════════════════════════════════════════
class _ObsidianForecastPainter extends CustomPainter {
  final List<double> actual, forecast;
  final List<bool> anomalyFlags;
  final double stdDev, minY, maxY;
  final Color color;

  const _ObsidianForecastPainter({
    required this.actual,
    required this.forecast,
    required this.anomalyFlags,
    required this.stdDev,
    required this.color,
    required this.minY,
    required this.maxY,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final range = maxY - minY == 0 ? 1.0 : maxY - minY;
    final n = actual.length;
    final f = forecast.length;
    final total = n + f;

    double xOf(int i) => size.width * i / (total - 1 == 0 ? 1 : total - 1);
    double yOf(double v) => size.height - ((v - minY) / range) * size.height;

    // Grid lines — subtle
    final gridP = Paint()
      ..color = const Color(0xFF2A2A2B)
      ..strokeWidth = 0.5;
    for (int i = 0; i <= 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridP);
    }

    // Forecast divider
    if (n > 0 && f > 0) {
      canvas.drawLine(
        Offset(xOf(n - 1), 0),
        Offset(xOf(n - 1), size.height),
        Paint()
          ..color = color.withValues(alpha: 0.15)
          ..strokeWidth = 1,
      );
    }

    // Confidence band
    if (f > 0 && stdDev > 0) {
      final bp = ui.Path()
        ..moveTo(xOf(n - 1), yOf(actual.last + 1.96 * stdDev));
      for (int i = 0; i < f; i++) {
        final hw = 1.96 * stdDev * math.sqrt(i + 1.0);
        bp.lineTo(xOf(n + i), yOf(forecast[i] + hw));
      }
      for (int i = f - 1; i >= 0; i--) {
        final hw = 1.96 * stdDev * math.sqrt(i + 1.0);
        bp.lineTo(xOf(n + i), yOf(forecast[i] - hw));
      }
      bp.lineTo(xOf(n - 1), yOf(actual.last - 1.96 * stdDev));
      bp.close();
      canvas.drawPath(bp, Paint()..color = color.withValues(alpha: 0.10));
    }

    // Area fill
    if (n > 0) {
      final fp = ui.Path()..moveTo(xOf(0), yOf(actual[0]));
      final lp = ui.Path()..moveTo(xOf(0), yOf(actual[0]));
      for (int i = 1; i < n; i++) {
        fp.lineTo(xOf(i), yOf(actual[i]));
        lp.lineTo(xOf(i), yOf(actual[i]));
      }
      fp.lineTo(xOf(n - 1), size.height);
      fp.lineTo(0, size.height);
      fp.close();
      canvas.drawPath(
        fp,
        Paint()
          ..shader = ui.Gradient.linear(Offset.zero, Offset(0, size.height), [
            color.withValues(alpha: 0.18),
            color.withValues(alpha: 0.0),
          ]),
      );
      canvas.drawPath(
        lp,
        Paint()
          ..color = color
          ..strokeWidth = 1.8
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    // Forecast dashed
    if (f > 0 && n > 0) {
      final dp = Paint()
        ..color = const Color(0xFFADC6FF).withValues(alpha: 0.6)
        ..strokeWidth = 1.4
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      double sx = xOf(n - 1), sy = yOf(actual.last);
      for (int i = 0; i < f; i++) {
        final ex = xOf(n + i), ey = yOf(forecast[i]);
        final dx = ex - sx, dy = ey - sy;
        final dist = math.sqrt(dx * dx + dy * dy);
        if (dist < 0.1) {
          sx = ex;
          sy = ey;
          continue;
        }
        final ux = dx / dist, uy = dy / dist;
        double pos = 0;
        bool d = true;
        while (pos < dist) {
          final seg = d ? 5.0 : 4.0;
          final end = math.min(pos + seg, dist);
          if (d) {
            canvas.drawLine(
              Offset(sx + ux * pos, sy + uy * pos),
              Offset(sx + ux * end, sy + uy * end),
              dp,
            );
          }
          pos += seg;
          d = !d;
        }
        sx = ex;
        sy = ey;
      }
    }

    // Anomaly dots
    for (int i = 0; i < n && i < anomalyFlags.length; i++) {
      if (!anomalyFlags[i]) continue;
      canvas.drawCircle(
        Offset(xOf(i), yOf(actual[i])),
        5,
        Paint()
          ..color = const Color(0xFFFF6B6B)
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        Offset(xOf(i), yOf(actual[i])),
        5,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.3)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }

    // Live dot
    if (n > 0) {
      canvas.drawCircle(
        Offset(xOf(n - 1), yOf(actual.last)),
        4,
        Paint()
          ..color = color
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        Offset(xOf(n - 1), yOf(actual.last)),
        4,
        Paint()
          ..color = C.surfaceHigh
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(_ObsidianForecastPainter old) => true;
}

// ══════════════════════════════════════════════════════════════════════════
// OBSIDIAN DUAL PAINTER
// ══════════════════════════════════════════════════════════════════════════
// ══════════════════════════════════════════════════════════════════════════
// OBSIDIAN TRIPLE PAINTER
// ══════════════════════════════════════════════════════════════════════════
class _ObsidianTriplePainter extends CustomPainter {
  final List<double> actualA, actualB, actualC, forecastA, forecastB, forecastC;
  final List<bool> anomalyA, anomalyB, anomalyC;
  final Color colorA, colorB, colorC;
  final double minY, maxY;

  const _ObsidianTriplePainter({
    required this.actualA,
    required this.actualB,
    required this.actualC,
    required this.forecastA,
    required this.forecastB,
    required this.forecastC,
    required this.anomalyA,
    required this.anomalyB,
    required this.anomalyC,
    required this.colorA,
    required this.colorB,
    required this.colorC,
    required this.minY,
    required this.maxY,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final range = maxY - minY == 0 ? 1.0 : maxY - minY;
    final n = actualA.length;
    final f = forecastA.length;
    final total = n + f;

    double xOf(int i) => size.width * i / (total - 1 == 0 ? 1 : total - 1);
    double yOf(double v) => size.height - ((v - minY) / range) * size.height;

    final gridP = Paint()
      ..color = const Color(0xFF2A2A2B)
      ..strokeWidth = 0.5;
    for (int i = 0; i <= 4; i++) {
      canvas.drawLine(
        Offset(0, size.height * i / 4),
        Offset(size.width, size.height * i / 4),
        gridP,
      );
    }

    // Zero line
    final zero = yOf(0).clamp(0.0, size.height);
    canvas.drawLine(
      Offset(0, zero),
      Offset(size.width, zero),
      Paint()
        ..color = const Color(0xFF353436)
        ..strokeWidth = 0.8,
    );

    void drawS(
      List<double> actual,
      List<double> forecast,
      List<bool> anomalies,
      Color color, {
      bool dashed = false,
    }) {
      if (actual.isEmpty) return;
      final lp = ui.Path()..moveTo(xOf(0), yOf(actual[0]));
      for (int i = 1; i < actual.length; i++) {
        lp.lineTo(xOf(i), yOf(actual[i]));
      }
      canvas.drawPath(
        lp,
        Paint()
          ..color = color
          ..strokeWidth = dashed ? 1.2 : 1.6
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );

      if (forecast.isNotEmpty) {
        double sx = xOf(n - 1), sy = yOf(actual.last);
        final dp = Paint()
          ..color = color.withValues(alpha: 0.4)
          ..strokeWidth = 1.2
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round;
        for (int i = 0; i < forecast.length; i++) {
          final ex = xOf(n + i), ey = yOf(forecast[i]);
          final dx = ex - sx, dy = ey - sy;
          final dist = math.sqrt(dx * dx + dy * dy);
          if (dist < 0.1) {
            sx = ex;
            sy = ey;
            continue;
          }
          final ux = dx / dist, uy = dy / dist;
          double pos = 0;
          bool d = true;
          while (pos < dist) {
            final seg = d ? 5.0 : 4.0;
            final end = math.min(pos + seg, dist);
            if (d) {
              canvas.drawLine(
                Offset(sx + ux * pos, sy + uy * pos),
                Offset(sx + ux * end, sy + uy * end),
                dp,
              );
            }
            pos += seg;
            d = !d;
          }
          sx = ex;
          sy = ey;
        }
      }
      for (int i = 0; i < actual.length && i < anomalies.length; i++) {
        if (!anomalies[i]) continue;
        canvas.drawCircle(
          Offset(xOf(i), yOf(actual[i])),
          4,
          Paint()
            ..color = const Color(0xFFFF6B6B)
            ..style = PaintingStyle.fill,
        );
      }
      if (actual.isNotEmpty) {
        canvas.drawCircle(
          Offset(xOf(n - 1), yOf(actual.last)),
          3,
          Paint()
            ..color = color
            ..style = PaintingStyle.fill,
        );
      }
    }

    drawS(actualA, forecastA, anomalyA, colorA);
    drawS(actualB, forecastB, anomalyB, colorB, dashed: true);
    drawS(actualC, forecastC, anomalyC, colorC, dashed: true);
  }

  @override
  bool shouldRepaint(_ObsidianTriplePainter old) => true;
}

// ══════════════════════════════════════════════════════════════════════════
// VECTOR PROJECTION PAINTER
// ══════════════════════════════════════════════════════════════════════════
class _VectorProjectionPainter extends CustomPainter {
  final List<LatLng> forecast;
  const _VectorProjectionPainter({required this.forecast});

  @override
  void paint(Canvas canvas, Size size) {
    if (forecast.isEmpty) return;
    final gridP = Paint()
      ..color = const Color(0xFF1C1B1C)
      ..strokeWidth = 0.5;
    for (int i = 0; i <= 6; i++) {
      canvas.drawLine(
        Offset(0, size.height * i / 6),
        Offset(size.width, size.height * i / 6),
        gridP,
      );
      canvas.drawLine(
        Offset(size.width * i / 6, 0),
        Offset(size.width * i / 6, size.height),
        gridP,
      );
    }

    final pts = forecast.take(8).toList();
    if (pts.length < 2) return;

    // Normalize to screen coords
    final lats = pts.map((p) => p.latitude).toList();
    final lngs = pts.map((p) => p.longitude).toList();
    final minLat = lats.reduce(math.min), maxLat = lats.reduce(math.max);
    final minLng = lngs.reduce(math.min), maxLng = lngs.reduce(math.max);
    final latRange = (maxLat - minLat).abs().clamp(0.0001, double.infinity);
    final lngRange = (maxLng - minLng).abs().clamp(0.0001, double.infinity);

    final path = ui.Path();
    for (int i = 0; i < pts.length; i++) {
      final x =
          ((pts[i].longitude - minLng) / lngRange) * size.width * 0.8 +
          size.width * 0.1;
      final y =
          size.height -
          ((pts[i].latitude - minLat) / latRange) * size.height * 0.7 -
          size.height * 0.15;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    // Draw dashed
    final pm = Paint()
      ..color = const Color(0xFF353436)
      ..strokeWidth = 0.5;
    canvas.drawPath(path, pm);
    for (int i = 0; i < pts.length; i++) {
      final x =
          ((pts[i].longitude - minLng) / lngRange) * size.width * 0.8 +
          size.width * 0.1;
      final y =
          size.height -
          ((pts[i].latitude - minLat) / latRange) * size.height * 0.7 -
          size.height * 0.15;
      final conf = 1.0 - i * 0.1;
      canvas.drawCircle(
        Offset(x, y),
        4,
        Paint()..color = const Color(0xFFADC6FF).withValues(alpha: conf),
      );
    }
  }

  @override
  bool shouldRepaint(_VectorProjectionPainter old) => true;
}

// ══════════════════════════════════════════════════════════════════════════
// OBSIDIAN VIEWFINDER PAINTER
// ══════════════════════════════════════════════════════════════════════════
class _ObsidianViewfinderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0xFF4EDEA3).withValues(alpha: 0.7)
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.square;
    const len = 16.0, pad = 14.0;
    // Top-left
    canvas.drawLine(Offset(pad, pad + len), Offset(pad, pad), p);
    canvas.drawLine(Offset(pad, pad), Offset(pad + len, pad), p);
    // Top-right
    canvas.drawLine(
      Offset(size.width - pad - len, pad),
      Offset(size.width - pad, pad),
      p,
    );
    canvas.drawLine(
      Offset(size.width - pad, pad),
      Offset(size.width - pad, pad + len),
      p,
    );
    // Bottom-left
    canvas.drawLine(
      Offset(pad, size.height - pad - len),
      Offset(pad, size.height - pad),
      p,
    );
    canvas.drawLine(
      Offset(pad, size.height - pad),
      Offset(pad + len, size.height - pad),
      p,
    );
    // Bottom-right
    canvas.drawLine(
      Offset(size.width - pad - len, size.height - pad),
      Offset(size.width - pad, size.height - pad),
      p,
    );
    canvas.drawLine(
      Offset(size.width - pad, size.height - pad - len),
      Offset(size.width - pad, size.height - pad),
      p,
    );
  }

  @override
  bool shouldRepaint(_ObsidianViewfinderPainter old) => false;
}

// ══════════════════════════════════════════════════════════════════════════
// LEGEND LINE PAINTER
// ══════════════════════════════════════════════════════════════════════════
class _ObsLegendLine extends CustomPainter {
  final Color color;
  final bool dashed;
  const _ObsLegendLine({required this.color, this.dashed = false});

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    if (!dashed) {
      canvas.drawLine(
        Offset(0, size.height / 2),
        Offset(size.width, size.height / 2),
        p,
      );
    } else {
      double x = 0;
      bool d = true;
      while (x < size.width) {
        final end = math.min(x + 5, size.width);
        if (d) {
          canvas.drawLine(
            Offset(x, size.height / 2),
            Offset(end, size.height / 2),
            p,
          );
        }
        x += 5;
        d = !d;
      }
    }
  }

  @override
  bool shouldRepaint(_ObsLegendLine old) => false;
}
