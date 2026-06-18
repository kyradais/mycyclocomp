import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
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
        repository: widget.repository ?? GeolocatorCyclocompRepository(),
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

  @override
  void initState() {
    super.initState();
    _reading = widget.repository.initial;
    _subscription = widget.repository.watch().listen((reading) {
      if (!mounted) {
        return;
      }
      setState(() => _reading = reading);
      if (_mapReady && reading.position != null) {
        _mapController.move(reading.position!, _mapController.camera.zoom);
        _applyMapOrientation();
      }
    });
    widget.repository.start();
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
          SpeedometerPage(reading: _reading, darkUi: widget.darkUi),
          MapPage(
            reading: _reading,
            mapController: _mapController,
            useLiveMap: widget.useLiveMap,
            darkUi: widget.darkUi,
            fixNorth: _fixNorth,
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
    required this.darkUi,
  });

  final CyclocompReading reading;
  final bool darkUi;

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
  });

  final String distance;
  final String duration;
  final String subtitle;
  final bool darkUi;

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
    required this.onToggleFixNorth,
    required this.onToggleUiTheme,
    required this.onMapReady,
  });

  final CyclocompReading reading;
  final MapController mapController;
  final bool useLiveMap;
  final bool darkUi;
  final bool fixNorth;
  final VoidCallback onToggleFixNorth;
  final VoidCallback onToggleUiTheme;
  final VoidCallback onMapReady;

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
                    const Spacer(),
                    Center(
                      child: _CenterUserMarker(darkUi: darkUi),
                    ),
                    const Spacer(),
                    _MapFooter(
                      coordinateText: position == null
                          ? 'Koordinat belum tersedia'
                          : '${position.latitude.toStringAsFixed(6)}, ${position.longitude.toStringAsFixed(6)}',
                      accuracyText: reading.accuracyMeters == null
                          ? 'Menunggu GPS'
                          : 'Akurasi ±${reading.accuracyMeters!.toStringAsFixed(1)} m',
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              right: 20,
              bottom: 98,
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
          icon: darkUi ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
          isActive: darkUi,
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
    return Material(
      color: isActive
          ? (darkUi
              ? const Color(0xFF4DE1A1).withOpacity(0.18)
              : const Color(0xFF0E5E4C).withOpacity(0.14))
          : (darkUi ? Colors.black.withOpacity(0.42) : Colors.white.withOpacity(0.96)),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isActive
                  ? (darkUi
                      ? const Color(0xFF4DE1A1).withOpacity(0.55)
                      : const Color(0xFF0E5E4C).withOpacity(0.35))
                  : (darkUi ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.08)),
            ),
          ),
          child: Icon(
            icon,
            color: isActive
                ? (darkUi ? const Color(0xFF4DE1A1) : const Color(0xFF0E5E4C))
                : (darkUi ? Colors.white : Colors.black87),
            size: 26,
          ),
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
  const _CenterUserMarker({required this.darkUi});

  final bool darkUi;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.92, end: 1.1),
      duration: const Duration(milliseconds: 1300),
      curve: Curves.easeInOut,
      builder: (context, value, child) {
        return Transform.scale(scale: value, child: child);
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.navigation_rounded,
            size: 34,
            color: darkUi ? const Color(0xFF4DE1A1) : const Color(0xFF0E5E4C),
            shadows: [
              Shadow(
                color: Colors.black.withOpacity(0.2),
                blurRadius: 12,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MapFooter extends StatelessWidget {
  const _MapFooter({
    required this.coordinateText,
    required this.accuracyText,
  });

  final String coordinateText;
  final String accuracyText;

  @override
  Widget build(BuildContext context) {
    final bgDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: bgDark ? Colors.white.withOpacity(0.06) : Colors.white.withOpacity(0.72),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: bgDark ? Colors.white.withOpacity(0.09) : Colors.black.withOpacity(0.08),
        ),
        boxShadow: [
          if (!bgDark)
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
        ],
      ),
      child: Row(
        children: [
          Icon(
            Icons.location_on,
            color: bgDark ? const Color(0xFF4DE1A1) : const Color(0xFF0E5E4C),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '$coordinateText\n$accuracyText',
              style: TextStyle(
                color: bgDark ? Colors.white70 : Colors.black54,
                height: 1.35,
              ),
            ),
          ),
        ],
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
    required this.statusText,
    required this.mapStatusText,
  });

  final LatLng? position;
  final double? accuracyMeters;
  final double speedKmh;
  final double distanceMeters;
  final Duration duration;
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
    String? statusText,
    String? mapStatusText,
  }) {
    return CyclocompReading(
      position: position ?? this.position,
      accuracyMeters: accuracyMeters ?? this.accuracyMeters,
      speedKmh: speedKmh ?? this.speedKmh,
      distanceMeters: distanceMeters ?? this.distanceMeters,
      duration: duration ?? this.duration,
      statusText: statusText ?? this.statusText,
      mapStatusText: mapStatusText ?? this.mapStatusText,
    );
  }
}

abstract class CyclocompRepository {
  CyclocompReading get initial;

  Stream<CyclocompReading> watch();

  void start();

  void dispose();
}

class GeolocatorCyclocompRepository implements CyclocompRepository {
  GeolocatorCyclocompRepository();

  final StreamController<CyclocompReading> _controller =
      StreamController<CyclocompReading>.broadcast();
  StreamSubscription<Position>? _subscription;
  CyclocompReading _current = CyclocompReading.idle('Menunggu GPS...');
  Position? _lastPosition;
  DateTime? _startedAt;
  double _distanceMeters = 0;

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
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 3,
        ),
      );
      _handlePosition(firstPosition);

      _subscription = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 3,
        ),
      ).listen(_handlePosition);
    } catch (error) {
      _emitStatus('GPS belum tersedia: $error');
    }
  }

  void _handlePosition(Position position) {
    final now = DateTime.now();
    _startedAt ??= now;

    if (_lastPosition != null) {
      _distanceMeters += Geolocator.distanceBetween(
        _lastPosition!.latitude,
        _lastPosition!.longitude,
        position.latitude,
        position.longitude,
      );
    }

    _lastPosition = position;

    final speedFromSensor = position.speed.isFinite ? position.speed * 3.6 : 0.0;
    final status = speedFromSensor > 0.5 ? 'GPS live' : 'Berhenti / pelan';

    _current = CyclocompReading(
      position: LatLng(position.latitude, position.longitude),
      accuracyMeters: position.accuracy,
      speedKmh: speedFromSensor.toDouble(),
      distanceMeters: _distanceMeters,
      duration: now.difference(_startedAt!),
      statusText: status,
      mapStatusText:
          'Titik user mengikuti koordinat GPS aktual dan tetap berada di tengah map.',
    );
    _controller.add(_current);
  }

  void _emitStatus(String message) {
    _current = CyclocompReading.idle(message);
    _controller.add(_current);
  }

  @override
  void dispose() {
    _subscription?.cancel();
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
    distanceMeters: 12400,
    duration: const Duration(minutes: 38, seconds: 12),
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
  void dispose() {
    _controller.close();
  }
}
