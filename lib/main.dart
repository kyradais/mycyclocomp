import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:gpx/gpx.dart';
import 'package:latlong2/latlong.dart';

void main() {
  runApp(const CyclocompApp());
}

class CyclocompApp extends StatefulWidget {
  const CyclocompApp({
    super.key,
    this.repository,
    this.useLiveMap = true,
  });

  final CyclocompRepository? repository;
  final bool useLiveMap;

  @override
  State<CyclocompApp> createState() => _CyclocompAppState();
}

class _CyclocompAppState extends State<CyclocompApp> {
  bool _darkUi = true;
  late final CyclocompRepository _repository;
  late final bool _ownsRepository;

  @override
  void initState() {
    super.initState();
    _ownsRepository = widget.repository == null;
    _repository = widget.repository ?? GeolocatorCyclocompRepository();
  }

  @override
  void dispose() {
    if (_ownsRepository) {
      _repository.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final darkTheme = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF4DE1A1),
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: const Color(0xFF081018),
    );
    final lightTheme = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF0E5E4C),
        brightness: Brightness.light,
      ),
      scaffoldBackgroundColor: const Color(0xFFF3F6F4),
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Cyclocomp',
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: _darkUi ? ThemeMode.dark : ThemeMode.light,
      home: CyclocompHome(
        repository: _repository,
        useLiveMap: widget.useLiveMap,
        darkUi: _darkUi,
        onToggleUiTheme: () {
          setState(() {
            _darkUi = !_darkUi;
          });
        },
      ),
    );
  }
}

class CyclocompHome extends StatefulWidget {
  const CyclocompHome({
    super.key,
    required this.repository,
    required this.useLiveMap,
    required this.darkUi,
    required this.onToggleUiTheme,
  });

  final CyclocompRepository repository;
  final bool useLiveMap;
  final bool darkUi;
  final VoidCallback onToggleUiTheme;

  @override
  State<CyclocompHome> createState() => _CyclocompHomeState();
}

enum TripRecordingState {
  idle,
  running,
  paused,
}

class _CyclocompHomeState extends State<CyclocompHome> {
  final PageController _pageController = PageController();
  final MapController _mapController = MapController();

  late CyclocompReading _reading;
  StreamSubscription<CyclocompReading>? _subscription;
  StreamSubscription<CompassEvent>? _compassSubscription;
  int _pageIndex = 0;
  bool _mapReady = false;
  bool _fixNorth = true;
  double? _heading;

  // Jejak rute hijau saat record berjalan.
  final List<LatLng> _trailPoints = [];
  TripRecordingState _lastTripState = TripRecordingState.idle;

  // Rute GPX yang diupload manual oleh user.
  List<LatLng> _gpxRoutePoints = [];
  String? _gpxFileName;

  @override
  void initState() {
    super.initState();
    _reading = widget.repository.initial;
    _lastTripState = _reading.tripState;
    _subscription = widget.repository.watch().listen((reading) {
      if (!mounted) {
        return;
      }
      _handleTrailUpdate(reading);
      setState(() => _reading = reading);
      if (_mapReady && reading.position != null) {
        _mapController.move(reading.position!, _mapController.camera.zoom);
        _applyMapOrientation();
      }
    });
    widget.repository.start();
  }

  void _handleTrailUpdate(CyclocompReading reading) {
    final wasIdle = _lastTripState == TripRecordingState.idle;
    final isIdleNow = reading.tripState == TripRecordingState.idle;
    final isRunningNow = reading.tripState == TripRecordingState.running;

    // Trip baru saja di-stop -> reset jejak (hapus garis hijau).
    if (isIdleNow && !wasIdle) {
      _trailPoints.clear();
    }

    // Trip baru saja di-start dari idle -> mulai jejak baru dari titik sekarang.
    if (isRunningNow && wasIdle) {
      _trailPoints.clear();
      if (reading.position != null) {
        _trailPoints.add(reading.position!);
      }
    } else if (isRunningNow && reading.position != null) {
      // Hanya menambah titik jejak saat status running (tidak menambah saat paused).
      final last = _trailPoints.isEmpty ? null : _trailPoints.last;
      if (last == null ||
          last.latitude != reading.position!.latitude ||
          last.longitude != reading.position!.longitude) {
        _trailPoints.add(reading.position!);
      }
    }

    _lastTripState = reading.tripState;
  }

  Future<void> _pickGpxFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
      );
      if (result == null || result.files.isEmpty) {
        return;
      }
      final picked = result.files.single;
      final lowerName = picked.name.toLowerCase();
      if (!lowerName.endsWith('.gpx')) {
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pilih file dengan ekstensi .gpx')),
        );
        return;
      }
      final bytes = picked.bytes ??
          (picked.path != null ? await File(picked.path!).readAsBytes() : null);
      if (bytes == null) {
        return;
      }
      final xmlString = String.fromCharCodes(bytes);
      final gpx = GpxReader().fromString(xmlString);

      final points = <LatLng>[];
      for (final trk in gpx.trks) {
        for (final seg in trk.trksegs) {
          for (final point in seg.trkpts) {
            final lat = point.lat;
            final lon = point.lon;
            if (lat != null && lon != null) {
              points.add(LatLng(lat, lon));
            }
          }
        }
      }
      // Fallback ke rute (rte) jika file GPX tidak punya track.
      if (points.isEmpty) {
        for (final rte in gpx.rtes) {
          for (final point in rte.rtepts) {
            final lat = point.lat;
            final lon = point.lon;
            if (lat != null && lon != null) {
              points.add(LatLng(lat, lon));
            }
          }
        }
      }

      if (points.isEmpty || !mounted) {
        return;
      }

      setState(() {
        _gpxRoutePoints = points;
        _gpxFileName = picked.name;
      });

      _mapController.fitCamera(
        CameraFit.coordinates(
          coordinates: points,
          padding: const EdgeInsets.all(48),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gagal membaca file GPX: $error')),
      );
    }
  }

  void _clearGpxRoute() {
    setState(() {
      _gpxRoutePoints = [];
      _gpxFileName = null;
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _compassSubscription?.cancel();
    _pageController.dispose();
    _mapController.dispose();
    widget.repository.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageView(
        controller: _pageController,
        onPageChanged: (value) => setState(() => _pageIndex = value),
        children: [
          SpeedometerPage(
            reading: _reading,
            onStartTrip: widget.repository.startTrip,
            onPauseTrip: widget.repository.pauseTrip,
            onResumeTrip: widget.repository.resumeTrip,
            onStopTrip: widget.repository.stopTrip,
          ),
          MapPage(
            reading: _reading,
            mapController: _mapController,
            useLiveMap: widget.useLiveMap,
            darkUi: widget.darkUi,
            fixNorth: _fixNorth,
            trailPoints: _trailPoints,
            gpxRoutePoints: _gpxRoutePoints,
            gpxFileName: _gpxFileName,
            onPickGpxFile: _pickGpxFile,
            onClearGpxRoute: _clearGpxRoute,
            onToggleFixNorth: _toggleFixNorth,
            onToggleUiTheme: widget.onToggleUiTheme,
            onMapReady: () {
              if (!mounted) {
                return;
              }
              setState(() => _mapReady = true);
              final position = _reading.position;
              if (position != null) {
                _mapController.move(position, _mapController.camera.zoom);
                _applyMapOrientation();
              }
            },
          ),
        ],
      ),
      bottomNavigationBar: _PageHintBar(pageIndex: _pageIndex),
    );
  }

  void _toggleFixNorth() {
    setState(() {
      _fixNorth = !_fixNorth;
    });

    if (_fixNorth) {
      _compassSubscription?.cancel();
      _compassSubscription = null;
      if (_mapReady) {
        _mapController.rotate(0.0);
      }
      return;
    }

    _compassSubscription ??=
        FlutterCompass.events?.listen((CompassEvent event) {
      final heading = event.heading;
      if (heading == null || !mounted) {
        return;
      }
      setState(() => _heading = heading);
      _applyMapOrientation();
    });
  }

  void _applyMapOrientation() {
    if (!_mapReady) {
      return;
    }
    if (_fixNorth) {
      _mapController.rotate(0.0);
      return;
    }
    final heading = _heading;
    if (heading == null) {
      return;
    }
    _mapController.rotate(-heading);
  }
}

class _PageHintBar extends StatelessWidget {
  const _PageHintBar({required this.pageIndex});

  final int pageIndex;

  @override
  Widget build(BuildContext context) {
    final darkUi = Theme.of(context).brightness == Brightness.dark;
    return SafeArea(
      top: false,
      child: Container(
        height: 58,
        decoration: BoxDecoration(
          color: darkUi
              ? const Color(0xFF0D1721).withOpacity(0.9)
              : Colors.white.withOpacity(0.92),
          border: Border(
            top: BorderSide(
              color: darkUi ? Colors.white.withOpacity(0.06) : Colors.black.withOpacity(0.08),
            ),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _Dot(active: pageIndex == 0),
            const SizedBox(width: 10),
            _Dot(active: pageIndex == 1),
          ],
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final darkUi = Theme.of(context).brightness == Brightness.dark;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      width: active ? 22 : 8,
      height: 8,
      decoration: BoxDecoration(
        color: active
            ? const Color(0xFF4DE1A1)
            : (darkUi ? Colors.white24 : Colors.black26),
        borderRadius: BorderRadius.circular(99),
      ),
    );
  }
}

class SpeedometerPage extends StatelessWidget {
  const SpeedometerPage({
    super.key,
    required this.reading,
    required this.onStartTrip,
    required this.onPauseTrip,
    required this.onResumeTrip,
    required this.onStopTrip,
  });

  final CyclocompReading reading;
  final VoidCallback onStartTrip;
  final VoidCallback onPauseTrip;
  final VoidCallback onResumeTrip;
  final VoidCallback onStopTrip;

  @override
  Widget build(BuildContext context) {
    final darkUi = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: darkUi
              ? const [
                  Color(0xFF081018),
                  Color(0xFF0D1721),
                  Color(0xFF061017),
                ]
              : const [
                  Color(0xFFF7FAF8),
                  Color(0xFFE8F1EC),
                  Color(0xFFFDFEFE),
                ],
        ),
      ),
      child: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: _SpeedometerBackdrop(darkUi: darkUi)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                children: [
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      _HeaderChip(
                        icon: Icons.directions_bike,
                        label: 'Cyclocomp',
                        darkUi: darkUi,
                      ),
                      const Spacer(),
                      _HeaderChip(
                        icon: Icons.swipe_left,
                        label: 'Swipe ke Map',
                        darkUi: darkUi,
                      ),
                    ],
                  ),
                  const Spacer(),
                  Center(
                    child: _SpeedometerGauge(
                      speedKmh: reading.speedKmh,
                      status: reading.statusText,
                      darkUi: darkUi,
                    ),
                  ),
                  const Spacer(),
                  _TripStatsCard(
                    distance: reading.distanceText,
                    duration: reading.durationText,
                    subtitle: reading.detailText,
                    darkUi: darkUi,
                    tripState: reading.tripState,
                    onStartTrip: onStartTrip,
                    onPauseTrip: onPauseTrip,
                    onResumeTrip: onResumeTrip,
                    onStopTrip: onStopTrip,
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderChip extends StatelessWidget {
  const _HeaderChip({
    required this.icon,
    required this.label,
    required this.darkUi,
  });

  final IconData icon;
  final String label;
  final bool darkUi;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: darkUi ? Colors.white.withOpacity(0.06) : Colors.black.withOpacity(0.04),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: darkUi ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.08),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 16,
            color: darkUi ? const Color(0xFF4DE1A1) : const Color(0xFF0E5E4C),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: darkUi ? Colors.white : Colors.black87,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _SpeedometerBackdrop extends StatelessWidget {
  const _SpeedometerBackdrop({required this.darkUi});

  final bool darkUi;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _BackdropPainter(darkUi: darkUi));
  }
}

class _BackdropPainter extends CustomPainter {
  _BackdropPainter({required this.darkUi});

  final bool darkUi;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    for (var i = 0; i < 9; i++) {
      paint.color = darkUi
          ? Colors.white.withOpacity(0.03 + i * 0.004)
          : Colors.black.withOpacity(0.02 + i * 0.003);
      final radius = size.width * 0.16 + i * 28;
      canvas.drawCircle(
        Offset(size.width / 2, size.height * 0.58),
        radius,
        paint,
      );
    }

    final glow = Paint()
      ..shader = RadialGradient(
        colors: [
          (darkUi ? const Color(0xFF4DE1A1) : const Color(0xFF0E5E4C))
              .withOpacity(0.18),
          Colors.transparent,
        ],
      ).createShader(
        Rect.fromCircle(
          center: Offset(size.width / 2, size.height * 0.58),
          radius: size.width * 0.45,
        ),
      );

    canvas.drawCircle(
      Offset(size.width / 2, size.height * 0.58),
      size.width * 0.45,
      glow,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _SpeedometerGauge extends StatelessWidget {
  const _SpeedometerGauge({
    required this.speedKmh,
    required this.status,
    required this.darkUi,
  });

  final double speedKmh;
  final String status;
  final bool darkUi;

  @override
  Widget build(BuildContext context) {
    final darkUi = Theme.of(context).brightness == Brightness.dark;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: speedKmh),
      duration: const Duration(milliseconds: 700),
      curve: Curves.easeOutCubic,
      builder: (context, value, _) {
        return SizedBox(
          width: 320,
          height: 320,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CustomPaint(
                size: const Size(320, 320),
                painter: _GaugePainter(value, darkUi: darkUi),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    value.toStringAsFixed(1),
                    style: TextStyle(
                      color: darkUi ? Colors.white : Colors.black87,
                      fontSize: 76,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -2,
                      height: 0.95,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'km/h',
                    style: TextStyle(
                      color: darkUi ? Colors.white70 : Colors.black54,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    status,
                    style: TextStyle(
                      color: darkUi ? Colors.white54 : Colors.black45,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter(this.speed, {required this.darkUi});

  final double speed;
  final bool darkUi;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width * 0.36;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 18
      ..strokeCap = StrokeCap.round
      ..color = darkUi
          ? Colors.white.withOpacity(0.08)
          : Colors.black.withOpacity(0.16);
    canvas.drawArc(rect, math.pi * 0.85, math.pi * 1.3, false, trackPaint);

    final progress = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 18
      ..strokeCap = StrokeCap.round
      ..shader = const LinearGradient(
        colors: [Color(0xFF4DE1A1), Color(0xFF83F0C1)],
      ).createShader(rect);
    canvas.drawArc(
      rect,
      math.pi * 0.85,
      math.pi * 1.3 * (speed / 60).clamp(0.0, 1.0),
      false,
      progress,
    );

    for (var i = 0; i <= 10; i++) {
      final tickAngle = math.pi * 0.85 + (math.pi * 1.3 / 10) * i;
      final outer = Offset(
        center.dx + math.cos(tickAngle) * (radius + 16),
        center.dy + math.sin(tickAngle) * (radius + 16),
      );
      final inner = Offset(
        center.dx + math.cos(tickAngle) * (radius - (i.isEven ? 18 : 12)),
        center.dy + math.sin(tickAngle) * (radius - (i.isEven ? 18 : 12)),
      );
      canvas.drawLine(
        inner,
        outer,
        Paint()
          ..strokeWidth = i.isEven ? 3 : 2
          ..strokeCap = StrokeCap.round
          ..color = darkUi
              ? Colors.white.withOpacity(i.isEven ? 0.45 : 0.18)
              : Colors.black.withOpacity(i.isEven ? 0.42 : 0.14),
      );
    }

    final needleAngle = math.pi * 0.85 + (math.pi * 1.3 * (speed / 60));
    final needleLength = radius - 16;
    final needleEnd = Offset(
      center.dx + math.cos(needleAngle) * needleLength,
      center.dy + math.sin(needleAngle) * needleLength,
    );

    canvas.drawLine(
      center,
      needleEnd,
      Paint()
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round
        ..color = const Color(0xFF4DE1A1),
    );

    canvas.drawCircle(
      center,
      14,
      Paint()
        ..color = darkUi ? const Color(0xFF4DE1A1) : const Color(0xFF0E5E4C),
    );
    canvas.drawCircle(
      center,
      6,
      Paint()..color = darkUi ? Colors.white : Colors.black87,
    );
  }

  @override
  bool shouldRepaint(covariant _GaugePainter oldDelegate) {
    return oldDelegate.speed != speed;
  }
}

class _TripStatsCard extends StatelessWidget {
  const _TripStatsCard({
    required this.distance,
    required this.duration,
    required this.subtitle,
    required this.darkUi,
    required this.tripState,
    required this.onStartTrip,
    required this.onPauseTrip,
    required this.onResumeTrip,
    required this.onStopTrip,
  });

  final String distance;
  final String duration;
  final String subtitle;
  final bool darkUi;
  final TripRecordingState tripState;
  final VoidCallback onStartTrip;
  final VoidCallback onPauseTrip;
  final VoidCallback onResumeTrip;
  final VoidCallback onStopTrip;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: darkUi ? Colors.white.withOpacity(0.06) : Colors.white,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: darkUi ? Colors.white.withOpacity(0.09) : Colors.black.withOpacity(0.08),
        ),
        boxShadow: [
          if (!darkUi)
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            subtitle,
            style: TextStyle(
              color: darkUi ? Colors.white70 : Colors.black54,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _MetricBlock(label: 'DISTANCE', value: distance),
              Container(width: 1, height: 46, color: darkUi ? Colors.white12 : Colors.black12),
              _MetricBlock(label: 'DURATION', value: duration),
            ],
          ),
          const SizedBox(height: 16),
          _TripControlPanel(
            darkUi: darkUi,
            tripState: tripState,
            onStartTrip: onStartTrip,
            onPauseTrip: onPauseTrip,
            onResumeTrip: onResumeTrip,
            onStopTrip: onStopTrip,
          ),
        ],
      ),
    );
  }
}

class _TripControlPanel extends StatefulWidget {
  const _TripControlPanel({
    required this.darkUi,
    required this.tripState,
    required this.onStartTrip,
    required this.onPauseTrip,
    required this.onResumeTrip,
    required this.onStopTrip,
  });

  final bool darkUi;
  final TripRecordingState tripState;
  final VoidCallback onStartTrip;
  final VoidCallback onPauseTrip;
  final VoidCallback onResumeTrip;
  final VoidCallback onStopTrip;

  @override
  State<_TripControlPanel> createState() => _TripControlPanelState();
}

class _TripControlPanelState extends State<_TripControlPanel> {
  static const Duration _stopHoldDuration = Duration(milliseconds: 1000);
  Timer? _stopHoldTimer;
  DateTime? _stopHoldStartedAt;
  double _stopHoldProgress = 0;
  bool _stopArmed = false;

  @override
  void dispose() {
    _cancelStopHold();
    super.dispose();
  }

  void _beginStopHold() {
    if (widget.tripState == TripRecordingState.idle) {
      return;
    }
    _stopHoldTimer?.cancel();
    _stopHoldStartedAt = DateTime.now();
    _stopArmed = true;
    setState(() => _stopHoldProgress = 0);
    _stopHoldTimer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
      if (!mounted || !_stopArmed || _stopHoldStartedAt == null) {
        timer.cancel();
        return;
      }

      final elapsed = DateTime.now().difference(_stopHoldStartedAt!);
      final progress = (elapsed.inMilliseconds / _stopHoldDuration.inMilliseconds).clamp(0.0, 1.0);
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _stopHoldProgress = progress);

      if (progress >= 1) {
        timer.cancel();
        _stopArmed = false;
        _stopHoldStartedAt = null;
        setState(() => _stopHoldProgress = 0);
        widget.onStopTrip();
      }
    });
  }

  void _cancelStopHold() {
    _stopHoldTimer?.cancel();
    _stopHoldTimer = null;
    _stopHoldStartedAt = null;
    _stopArmed = false;
    if (mounted && _stopHoldProgress != 0) {
      setState(() => _stopHoldProgress = 0);
    }
  }

  String get _stopHoldLabel {
    if (_stopHoldProgress <= 0) {
      return 'Stop';
    }
    final remaining = 1 - _stopHoldProgress;
    if (remaining > 0.66) {
      return '3';
    }
    if (remaining > 0.33) {
      return '2';
    }
    return '1';
  }

  void _handlePointerUp(_) => _cancelStopHold();

  void _handlePointerCancel() => _cancelStopHold();

  @override
  Widget build(BuildContext context) {
    final darkUi = widget.darkUi;
    final borderColor = darkUi ? Colors.white.withOpacity(0.09) : Colors.black.withOpacity(0.08);
    final bgColor = darkUi ? Colors.white.withOpacity(0.04) : Colors.white.withOpacity(0.62);
    final textColor = darkUi ? Colors.white : Colors.black87;
    final subtleText = darkUi ? Colors.white70 : Colors.black54;

    Widget controlButton({
      required IconData icon,
      required String label,
      required VoidCallback onTap,
      required bool active,
    }) {
      return Material(
        color: active
            ? (darkUi
                ? const Color(0xFF4DE1A1).withOpacity(0.16)
                : const Color(0xFF0E5E4C).withOpacity(0.12))
            : bgColor,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Container(
            height: 58,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: borderColor),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: active
                      ? (darkUi ? const Color(0xFF4DE1A1) : const Color(0xFF0E5E4C))
                      : textColor,
                ),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    color: active
                        ? (darkUi ? const Color(0xFFB7FFE0) : const Color(0xFF0E5E4C))
                        : textColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    Widget holdToStopButton() {
      final stopColor = darkUi ? const Color(0xFFFF6B7A) : const Color(0xFFB42318);
      final stopAccent = darkUi ? const Color(0xFFFF8A96) : const Color(0xFFE74C3C);
      return Listener(
        onPointerDown: (_) => _beginStopHold(),
        onPointerUp: _handlePointerUp,
        onPointerCancel: (_) => _handlePointerCancel(),
        child: Material(
          color: bgColor,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            onTap: () {},
            borderRadius: BorderRadius.circular(18),
            child: Container(
              height: 58,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: borderColor),
              ),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: _stopHoldProgress,
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  stopColor.withOpacity(0.55),
                                  stopAccent.withOpacity(0.35),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Center(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.stop_rounded,
                          size: 18,
                          color: _stopHoldProgress > 0.0 ? stopAccent : textColor,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _stopHoldLabel,
                          style: TextStyle(
                            color: _stopHoldProgress > 0.0 ? stopAccent : textColor,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        children: [
          Text(
            widget.tripState == TripRecordingState.idle
                ? 'Record belum dimulai'
                : widget.tripState == TripRecordingState.running
                    ? 'Record aktif'
                    : 'Record dijeda',
            style: TextStyle(
              color: subtleText,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 10),
          if (widget.tripState == TripRecordingState.idle)
            SizedBox(
              width: double.infinity,
              child: controlButton(
                icon: Icons.play_arrow_rounded,
                label: 'Start',
                onTap: widget.onStartTrip,
                active: false,
              ),
            )
          else ...[
            Row(
              children: [
                Expanded(
                  child: controlButton(
                    icon: widget.tripState == TripRecordingState.running
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    label: widget.tripState == TripRecordingState.running ? 'Pause' : 'Resume',
                    onTap: widget.tripState == TripRecordingState.running
                        ? widget.onPauseTrip
                        : widget.onResumeTrip,
                    active: true,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: holdToStopButton(),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _MetricBlock extends StatelessWidget {
  const _MetricBlock({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final darkUi = Theme.of(context).brightness == Brightness.dark;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            color: darkUi ? Colors.white54 : Colors.black54,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.1,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          value,
          style: TextStyle(
            color: darkUi ? Colors.white : Colors.black87,
            fontSize: 28,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class MapPage extends StatelessWidget {
  const MapPage({
    super.key,
    required this.reading,
    required this.mapController,
    required this.useLiveMap,
    required this.darkUi,
    required this.fixNorth,
    required this.trailPoints,
    required this.gpxRoutePoints,
    required this.gpxFileName,
    required this.onPickGpxFile,
    required this.onClearGpxRoute,
    required this.onToggleFixNorth,
    required this.onToggleUiTheme,
    required this.onMapReady,
  });

  final CyclocompReading reading;
  final MapController mapController;
  final bool useLiveMap;
  final bool darkUi;
  final bool fixNorth;
  final List<LatLng> trailPoints;
  final List<LatLng> gpxRoutePoints;
  final String? gpxFileName;
  final VoidCallback onPickGpxFile;
  final VoidCallback onClearGpxRoute;
  final VoidCallback onToggleFixNorth;
  final VoidCallback onToggleUiTheme;
  final VoidCallback onMapReady;

  static const Color _trailColor = Color(0xFF35E27A);
  static const Color _gpxColor = Color(0xFFFFD23F);

  List<Marker> _buildGpxArrowMarkers() {
    if (gpxRoutePoints.length < 2) {
      return const [];
    }
    const distance = Distance();

    // Hitung total panjang rute agar jarak antar panah konsisten (berbasis
    // jarak fisik, bukan jumlah titik) supaya tidak berdempetan di bagian
    // rute yang titiknya rapat (misal saat belok).
    var totalMeters = 0.0;
    for (var i = 0; i < gpxRoutePoints.length - 1; i++) {
      totalMeters += distance(gpxRoutePoints[i], gpxRoutePoints[i + 1]);
    }
    if (totalMeters <= 0) {
      return const [];
    }

    // Target sekitar 8-10 panah untuk rute sepanjang apapun, dengan jarak
    // minimum antar panah supaya tetap renggang pada rute pendek.
    const minSpacingMeters = 120.0;
    final spacingMeters = math.max(minSpacingMeters, totalMeters / 9);

    final markers = <Marker>[];
    var distanceSinceLastArrow = spacingMeters; // agar panah pertama langsung muncul
    for (var i = 0; i < gpxRoutePoints.length - 1; i++) {
      final from = gpxRoutePoints[i];
      final to = gpxRoutePoints[i + 1];
      final segmentLength = distance(from, to);
      distanceSinceLastArrow += segmentLength;

      if (distanceSinceLastArrow >= spacingMeters) {
        distanceSinceLastArrow = 0;
        final bearing = distance.bearing(from, to);
        markers.add(
          Marker(
            point: from,
            width: 22,
            height: 22,
            rotate: false,
            child: Transform.rotate(
              angle: bearing * (math.pi / 180),
              child: Icon(
                Icons.navigation_rounded,
                size: 18,
                color: _gpxColor,
                shadows: const [
                  Shadow(color: Colors.black54, blurRadius: 4),
                ],
              ),
            ),
          ),
        );
      }
    }
    return markers;
  }

  @override
  Widget build(BuildContext context) {
    final position = reading.position;
    final center = position ?? const LatLng(-7.2765, 112.7919);

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: darkUi
              ? const [
                  Color(0xFF07131C),
                  Color(0xFF0B1B20),
                  Color(0xFF081018),
                ]
              : const [
                  Color(0xFFF7FAF8),
                  Color(0xFFE8F1EC),
                  Color(0xFFFDFEFE),
                ],
        ),
      ),
      child: SafeArea(
        child: Stack(
          children: [
            const Positioned.fill(child: _MapBackdrop()),
            if (useLiveMap)
              FlutterMap(
                mapController: mapController,
                options: MapOptions(
                  initialCenter: center,
                  initialZoom: 16.0,
                  interactionOptions: const InteractionOptions(
                    flags: InteractiveFlag.pinchZoom | InteractiveFlag.doubleTapZoom,
                  ),
                  onMapReady: onMapReady,
                ),
                children: [
                  TileLayer(
                    urlTemplate: darkUi
                        ? 'https://basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png'
                        : 'https://basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png',
                    userAgentPackageName: 'com.example.mycyclocomp',
                  ),
                  if (gpxRoutePoints.length > 1)
                    PolylineLayer(
                      polylines: [
                        Polyline(
                          points: gpxRoutePoints,
                          strokeWidth: 4,
                          color: _gpxColor,
                          pattern: StrokePattern.dashed(segments: const [10.0, 8.0]),
                        ),
                      ],
                    ),
                  if (gpxRoutePoints.length > 1)
                    MarkerLayer(markers: _buildGpxArrowMarkers()),
                  if (trailPoints.length > 1)
                    PolylineLayer(
                      polylines: [
                        Polyline(
                          points: trailPoints,
                          strokeWidth: 5,
                          color: _trailColor,
                        ),
                      ],
                    ),
                ],
              )
            else
              _StaticMapPreview(showMarker: position != null),
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0x12000000),
                        Color(0x45000000),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            IgnorePointer(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _HeaderChip(
                          icon: Icons.map,
                          label: 'Map',
                          darkUi: darkUi,
                        ),
                        const Spacer(),
                        _HeaderChip(
                          icon: Icons.swipe_right,
                          label: 'Swipe kembali',
                          darkUi: darkUi,
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                  ],
                ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: _CenterUserMarker(darkUi: darkUi, fixNorth: fixNorth),
                ),
              ),
            ),
            Positioned(
              left: 20,
              right: 20,
              bottom: 20,
              child: SafeArea(
                top: false,
                child: _GpxUploadBar(
                  darkUi: darkUi,
                  gpxFileName: gpxFileName,
                  onPickGpxFile: onPickGpxFile,
                  onClearGpxRoute: onClearGpxRoute,
                ),
              ),
            ),
            Positioned(
              right: 20,
              bottom: 110,
              child: SafeArea(
                top: false,
                child: _MapToolStack(
                  fixNorth: fixNorth,
                  darkUi: darkUi,
                  onToggleFixNorth: onToggleFixNorth,
                  onToggleUiTheme: onToggleUiTheme,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MapToolStack extends StatelessWidget {
  const _MapToolStack({
    required this.darkUi,
    required this.fixNorth,
    required this.onToggleFixNorth,
    required this.onToggleUiTheme,
  });

  final bool darkUi;
  final bool fixNorth;
  final VoidCallback onToggleFixNorth;
  final VoidCallback onToggleUiTheme;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _MapIconButton(
          icon: darkUi ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
          isActive: true,
          onTap: onToggleUiTheme,
        ),
        const SizedBox(height: 10),
        _MapIconButton(
          icon: fixNorth ? Icons.explore_off_rounded : Icons.explore_rounded,
          isActive: !fixNorth,
          onTap: onToggleFixNorth,
        ),
      ],
    );
  }
}

class _MapIconButton extends StatelessWidget {
  const _MapIconButton({
    required this.icon,
    required this.isActive,
    required this.onTap,
  });

  final IconData icon;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final darkUi = Theme.of(context).brightness == Brightness.dark;
    final fillColor = isActive
        ? (darkUi
            ? const Color(0xFF4DE1A1).withOpacity(0.18)
            : const Color(0xFF0E5E4C).withOpacity(0.14))
        : (darkUi ? Colors.black.withOpacity(0.42) : Colors.white.withOpacity(0.96));
    final borderColor = isActive
        ? (darkUi
            ? const Color(0xFF4DE1A1).withOpacity(0.55)
            : const Color(0xFF0E5E4C).withOpacity(0.35))
        : (darkUi ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.08));

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 54,
        height: 54,
        decoration: BoxDecoration(
          color: fillColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borderColor),
        ),
        child: Icon(
          icon,
          color: isActive
              ? (darkUi ? const Color(0xFF4DE1A1) : const Color(0xFF0E5E4C))
              : (darkUi ? Colors.white : Colors.black87),
          size: 26,
        ),
      ),
    );
  }
}

class _StaticMapPreview extends StatelessWidget {
  const _StaticMapPreview({
    required this.showMarker,
  });

  final bool showMarker;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _PreviewMapPainter(showMarker: showMarker),
      child: const SizedBox.expand(),
    );
  }
}

class _PreviewMapPainter extends CustomPainter {
  _PreviewMapPainter({required this.showMarker});

  final bool showMarker;

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          const Color(0xFF173042),
          const Color(0xFF0E2418),
        ],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, bg);

    final roadPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final roads = <List<Offset>>[
      [Offset(size.width * 0.12, size.height * 0.22), Offset(size.width * 0.9, size.height * 0.2)],
      [Offset(size.width * 0.05, size.height * 0.45), Offset(size.width * 0.95, size.height * 0.5)],
      [Offset(size.width * 0.15, size.height * 0.7), Offset(size.width * 0.82, size.height * 0.64)],
    ];

    for (final road in roads) {
      roadPaint
        ..strokeWidth = 16
        ..color = Colors.black.withOpacity(0.18);
      canvas.drawLine(road.first, road.last, roadPaint);
      roadPaint
        ..strokeWidth = 9
        ..color = const Color(0xFFDBE8DC).withOpacity(0.28);
      canvas.drawLine(road.first, road.last, roadPaint);
    }

    if (showMarker) {
      final center = Offset(size.width / 2, size.height / 2);
      canvas.drawCircle(
        center,
        34,
        Paint()..color = const Color(0xFF4DE1A1).withOpacity(0.16),
      );
      canvas.drawCircle(
        center,
        11,
        Paint()..color = const Color(0xFF4DE1A1),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PreviewMapPainter oldDelegate) {
    return oldDelegate.showMarker != showMarker;
  }
}

class _MapBackdrop extends StatelessWidget {
  const _MapBackdrop();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _MapPainter());
  }
}

class _MapPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          const Color(0xFF0D2230).withOpacity(0.45),
          const Color(0xFF132B1E).withOpacity(0.35),
        ],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, bg);

    final gridPaint = Paint()
      ..color = Colors.white.withOpacity(0.05)
      ..strokeWidth = 1;

    const gridStep = 44.0;
    for (var x = 0.0; x <= size.width; x += gridStep) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (var y = 0.0; y <= size.height; y += gridStep) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _CenterUserMarker extends StatelessWidget {
  const _CenterUserMarker({required this.darkUi, required this.fixNorth});

  final bool darkUi;
  final bool fixNorth;

  @override
  Widget build(BuildContext context) {
    final accentColor = darkUi ? const Color(0xFF4DE1A1) : const Color(0xFF0E5E4C);

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.92, end: 1.1),
      duration: const Duration(milliseconds: 1300),
      curve: Curves.easeInOut,
      builder: (context, value, child) {
        return Transform.scale(scale: value, child: child);
      },
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        transitionBuilder: (child, animation) {
          return ScaleTransition(scale: animation, child: child);
        },
        child: fixNorth
            ? Container(
                key: const ValueKey('center-dot'),
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accentColor,
                  border: Border.all(
                    color: darkUi ? Colors.black.withOpacity(0.35) : Colors.white,
                    width: 3,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.2),
                      blurRadius: 12,
                    ),
                  ],
                ),
              )
            : Icon(
                Icons.navigation_rounded,
                key: const ValueKey('center-arrow'),
                size: 34,
                color: accentColor,
                shadows: [
                  Shadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 12,
                  ),
                ],
              ),
      ),
    );
  }
}

class _GpxUploadBar extends StatefulWidget {
  const _GpxUploadBar({
    required this.darkUi,
    required this.gpxFileName,
    required this.onPickGpxFile,
    required this.onClearGpxRoute,
  });

  final bool darkUi;
  final String? gpxFileName;
  final VoidCallback onPickGpxFile;
  final VoidCallback onClearGpxRoute;

  @override
  State<_GpxUploadBar> createState() => _GpxUploadBarState();
}

class _GpxUploadBarState extends State<_GpxUploadBar> {
  static const Duration _holdDuration = Duration(milliseconds: 1000);
  Timer? _holdTimer;
  DateTime? _holdStartedAt;
  double _holdProgress = 0;
  bool _holdArmed = false;

  @override
  void dispose() {
    _cancelHold();
    super.dispose();
  }

  void _beginHold() {
    _holdTimer?.cancel();
    _holdStartedAt = DateTime.now();
    _holdArmed = true;
    setState(() => _holdProgress = 0);
    _holdTimer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
      if (!mounted || !_holdArmed || _holdStartedAt == null) {
        timer.cancel();
        return;
      }
      final elapsed = DateTime.now().difference(_holdStartedAt!);
      final progress = (elapsed.inMilliseconds / _holdDuration.inMilliseconds).clamp(0.0, 1.0);
      setState(() => _holdProgress = progress);

      if (progress >= 1) {
        timer.cancel();
        _holdArmed = false;
        _holdStartedAt = null;
        setState(() => _holdProgress = 0);
        widget.onClearGpxRoute();
      }
    });
  }

  void _cancelHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _holdStartedAt = null;
    _holdArmed = false;
    if (mounted && _holdProgress != 0) {
      setState(() => _holdProgress = 0);
    }
  }

  String get _holdLabel {
    if (_holdProgress <= 0) {
      return '';
    }
    final remaining = 1 - _holdProgress;
    if (remaining > 0.66) {
      return '3';
    }
    if (remaining > 0.33) {
      return '2';
    }
    return '1';
  }

  @override
  Widget build(BuildContext context) {
    final darkUi = widget.darkUi;
    final bgColor = darkUi ? Colors.white.withOpacity(0.06) : Colors.white.withOpacity(0.72);
    final borderColor = darkUi ? Colors.white.withOpacity(0.09) : Colors.black.withOpacity(0.08);
    final textColor = darkUi ? Colors.white : Colors.black87;
    final subtleText = darkUi ? Colors.white70 : Colors.black54;
    const gpxColor = Color(0xFFFFD23F);

    final hasGpx = widget.gpxFileName != null;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: borderColor),
        boxShadow: [
          if (!darkUi)
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: hasGpx
            ? Row(
                children: [
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () {},
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Row(
                          children: [
                            Icon(Icons.route_rounded, color: gpxColor, size: 20),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'Rute GPX aktif',
                                    style: TextStyle(
                                      color: subtleText,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 0.8,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    widget.gpxFileName!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: textColor,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Listener(
                    onPointerDown: (_) => _beginHold(),
                    onPointerUp: (_) => _cancelHold(),
                    onPointerCancel: (_) => _cancelHold(),
                    child: Material(
                      color: darkUi ? Colors.black.withOpacity(0.28) : Colors.black.withOpacity(0.04),
                      borderRadius: BorderRadius.circular(16),
                      child: InkWell(
                        onTap: () {},
                        borderRadius: BorderRadius.circular(16),
                        child: Container(
                          width: 50,
                          height: 50,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: darkUi ? Colors.white.withOpacity(0.09) : Colors.black.withOpacity(0.08),
                            ),
                          ),
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(16),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: FractionallySizedBox(
                                      widthFactor: _holdProgress,
                                      child: Container(
                                        color: const Color(0xFFFF6B7A).withOpacity(0.55),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Center(
                                child: _holdProgress > 0
                                    ? Text(
                                        _holdLabel,
                                        style: const TextStyle(
                                          color: Color(0xFFFF8A96),
                                          fontSize: 15,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      )
                                    : Icon(Icons.close_rounded, color: textColor, size: 20),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              )
            : InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: widget.onPickGpxFile,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.upload_file_rounded, color: gpxColor, size: 20),
                      const SizedBox(width: 10),
                      Text(
                        'Upload Rute GPX',
                        style: TextStyle(
                          color: textColor,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

class CyclocompReading {
  const CyclocompReading({
    required this.position,
    required this.accuracyMeters,
    required this.speedKmh,
    required this.distanceMeters,
    required this.duration,
    required this.tripState,
    required this.statusText,
    required this.mapStatusText,
  });

  final LatLng? position;
  final double? accuracyMeters;
  final double speedKmh;
  final double distanceMeters;
  final Duration duration;
  final TripRecordingState tripState;
  final String statusText;
  final String mapStatusText;

  String get distanceText => '${(distanceMeters / 1000).toStringAsFixed(2)} km';

  String get durationText {
    final hours = duration.inHours.toString().padLeft(2, '0');
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  String get detailText => 'Distance  •  Duration';

  static CyclocompReading idle(String message) {
    return CyclocompReading(
      position: null,
      accuracyMeters: null,
      speedKmh: 0,
      distanceMeters: 0,
      duration: Duration.zero,
      tripState: TripRecordingState.idle,
      statusText: message,
      mapStatusText: message,
    );
  }

  CyclocompReading copyWith({
    LatLng? position,
    double? accuracyMeters,
    double? speedKmh,
    double? distanceMeters,
    Duration? duration,
    TripRecordingState? tripState,
    String? statusText,
    String? mapStatusText,
  }) {
    return CyclocompReading(
      position: position ?? this.position,
      accuracyMeters: accuracyMeters ?? this.accuracyMeters,
      speedKmh: speedKmh ?? this.speedKmh,
      distanceMeters: distanceMeters ?? this.distanceMeters,
      duration: duration ?? this.duration,
      tripState: tripState ?? this.tripState,
      statusText: statusText ?? this.statusText,
      mapStatusText: mapStatusText ?? this.mapStatusText,
    );
  }
}

abstract class CyclocompRepository {
  CyclocompReading get initial;

  Stream<CyclocompReading> watch();

  void start();

  void startTrip();

  void pauseTrip();

  void resumeTrip();

  void stopTrip();

  void dispose();
}

class GeolocatorCyclocompRepository implements CyclocompRepository {
  GeolocatorCyclocompRepository();

  final StreamController<CyclocompReading> _controller =
      StreamController<CyclocompReading>.broadcast();
  StreamSubscription<Position>? _subscription;
  Timer? _ticker;
  CyclocompReading _current = CyclocompReading.idle('Menunggu GPS...');
  Position? _lastPosition;
  TripRecordingState _tripState = TripRecordingState.idle;
  DateTime? _tripStartedAt;
  Duration _tripAccumulatedDuration = Duration.zero;
  double _tripDistanceMeters = 0;
  Position? _tripLastPosition;

  @override
  CyclocompReading get initial => _current;

  @override
  Stream<CyclocompReading> watch() => _controller.stream;

  @override
  void start() {
    if (_subscription != null) {
      return;
    }
    _bootstrap();
  }

  @override
  void startTrip() {
    _tripState = TripRecordingState.running;
    _tripStartedAt = DateTime.now();
    _tripAccumulatedDuration = Duration.zero;
    _tripDistanceMeters = 0;
    _tripLastPosition = _lastPosition;
    _startTicker();
    _emitCurrent();
  }

  @override
  void pauseTrip() {
    if (_tripState != TripRecordingState.running) {
      return;
    }
    _tripAccumulatedDuration += DateTime.now().difference(_tripStartedAt!);
    _tripStartedAt = null;
    _tripLastPosition = null;
    _tripState = TripRecordingState.paused;
    _stopTicker();
    _emitCurrent();
  }

  @override
  void resumeTrip() {
    if (_tripState != TripRecordingState.paused) {
      return;
    }
    _tripState = TripRecordingState.running;
    _tripStartedAt = DateTime.now();
    _tripLastPosition = _lastPosition;
    _startTicker();
    _emitCurrent();
  }

  @override
  void stopTrip() {
    _tripState = TripRecordingState.idle;
    _tripStartedAt = null;
    _tripAccumulatedDuration = Duration.zero;
    _tripDistanceMeters = 0;
    _tripLastPosition = null;
    _stopTicker();
    _emitCurrent();
  }

  Future<void> _bootstrap() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _emitStatus('Aktifkan lokasi untuk membaca speed dan peta');
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied) {
        _emitStatus('Izin lokasi ditolak');
        return;
      }
      if (permission == LocationPermission.deniedForever) {
        _emitStatus('Izin lokasi permanen ditolak');
        return;
      }

      final firstPosition = await Geolocator.getCurrentPosition(
        locationSettings: _locationSettings(),
      );
      _handlePosition(firstPosition);

      _subscription = Geolocator.getPositionStream(
        locationSettings: _locationSettings(),
      ).listen(_handlePosition);
    } catch (error) {
      _emitStatus('GPS belum tersedia: $error');
    }
  }

  void _handlePosition(Position position) {
    _lastPosition = position;

    final speedFromSensor = position.speed.isFinite ? position.speed * 3.6 : 0.0;
    if (_tripState == TripRecordingState.running) {
      if (_tripLastPosition != null) {
        _tripDistanceMeters += Geolocator.distanceBetween(
          _tripLastPosition!.latitude,
          _tripLastPosition!.longitude,
          position.latitude,
          position.longitude,
        );
      }
      _tripLastPosition = position;
    }

    _emitCurrent(
      speedText: speedFromSensor > 0.5 ? 'GPS live' : 'Berhenti / pelan',
    );
  }

  void _emitStatus(String message) {
    _current = CyclocompReading.idle(message);
    _controller.add(_current);
  }

  void _emitCurrent({
    String? speedText,
    String? mapStatusText,
  }) {
    final now = DateTime.now();
    final speedKmh = _lastPosition?.speed.isFinite == true
        ? _lastPosition!.speed * 3.6
        : 0.0;
    final duration = switch (_tripState) {
      TripRecordingState.idle => Duration.zero,
      TripRecordingState.running =>
        _tripAccumulatedDuration + now.difference(_tripStartedAt!),
      TripRecordingState.paused => _tripAccumulatedDuration,
    };

    final distanceMeters = switch (_tripState) {
      TripRecordingState.idle => 0.0,
      TripRecordingState.running => _tripDistanceMeters,
      TripRecordingState.paused => _tripDistanceMeters,
    };

    _current = CyclocompReading(
      position: _lastPosition == null
          ? null
          : LatLng(_lastPosition!.latitude, _lastPosition!.longitude),
      accuracyMeters: _lastPosition?.accuracy,
      speedKmh: speedKmh,
      distanceMeters: distanceMeters,
      duration: duration,
      tripState: _tripState,
      statusText: speedText ?? (speedKmh > 0.5 ? 'GPS live' : 'Berhenti / pelan'),
      mapStatusText:
          mapStatusText ?? 'Titik user mengikuti koordinat GPS aktual dan tetap berada di tengah map.',
    );
    _controller.add(_current);
  }

  void _startTicker() {
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (_tripState == TripRecordingState.running ||
          _tripState == TripRecordingState.paused) {
        _emitCurrent();
      }
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  LocationSettings _locationSettings() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 0,
          intervalDuration: const Duration(milliseconds: 500),
        );
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return AppleSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 0,
          pauseLocationUpdatesAutomatically: false,
          activityType: ActivityType.fitness,
        );
      default:
        return LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 0,
        );
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _stopTicker();
    _controller.close();
  }
}

class FakeCyclocompRepository implements CyclocompRepository {
  FakeCyclocompRepository._();

  factory FakeCyclocompRepository.demo() {
    return FakeCyclocompRepository._();
  }

  final StreamController<CyclocompReading> _controller =
      StreamController<CyclocompReading>.broadcast();
  late CyclocompReading _initial = CyclocompReading(
    position: const LatLng(-7.2765, 112.7919),
    accuracyMeters: 4.5,
    speedKmh: 28.4,
    distanceMeters: 0,
    duration: Duration.zero,
    tripState: TripRecordingState.idle,
    statusText: 'GPS live',
    mapStatusText: 'Demo data aktif untuk test atau preview UI.',
  );

  @override
  CyclocompReading get initial => _initial;

  @override
  Stream<CyclocompReading> watch() => _controller.stream;

  @override
  void start() {
    _controller.add(_initial);
  }

  @override
  void startTrip() {
    _initial = _initial.copyWith(
      tripState: TripRecordingState.running,
      distanceMeters: 0,
      duration: Duration.zero,
    );
    _controller.add(_initial);
  }

  @override
  void pauseTrip() {
    _initial = _initial.copyWith(tripState: TripRecordingState.paused);
    _controller.add(_initial);
  }

  @override
  void resumeTrip() {
    _initial = _initial.copyWith(tripState: TripRecordingState.running);
    _controller.add(_initial);
  }

  @override
  void stopTrip() {
    _initial = _initial.copyWith(
      tripState: TripRecordingState.idle,
      distanceMeters: 0,
      duration: Duration.zero,
    );
    _controller.add(_initial);
  }

  @override
  void dispose() {
    _controller.close();
  }
}
