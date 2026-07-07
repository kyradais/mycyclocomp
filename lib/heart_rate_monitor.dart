import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

// ============================================================================
// UUID standar BLE GATT "Heart Rate Service".
// Chest-strap (Polar H10, Garmin HRM, Wahoo TICKR) & sebagian smartwatch
// (Garmin, banyak Wear OS) broadcast service ini secara native.
// CATATAN: Apple Watch TIDAK broadcast HR lewat GATT standar ke app lain,
// jadi untuk iPhone/Apple Watch pairing ini tidak akan menemukan device.
// ============================================================================
final Guid heartRateServiceUuid = Guid('0000180d-0000-1000-8000-00805f9b34fb');
final Guid heartRateMeasurementUuid =
    Guid('00002a37-0000-1000-8000-00805f9b34fb');

enum HrConnectionState { disconnected, scanning, connecting, connected }

enum HrZone { istirahat, pemanasan, bakarLemak, aerobik, anaerobik, maksimal }

extension HrZoneX on HrZone {
  String get label {
    switch (this) {
      case HrZone.istirahat:
        return 'Istirahat';
      case HrZone.pemanasan:
        return 'Pemanasan';
      case HrZone.bakarLemak:
        return 'Bakar Lemak';
      case HrZone.aerobik:
        return 'Aerobik';
      case HrZone.anaerobik:
        return 'Anaerobik';
      case HrZone.maksimal:
        return 'Maksimal';
    }
  }

  /// Warna indikator zona — dibedakan jelas per level intensitas.
  Color get color {
    switch (this) {
      case HrZone.istirahat:
        return const Color(0xFF7C93A8); // abu kebiruan
      case HrZone.pemanasan:
        return const Color(0xFF4D9DE1); // biru
      case HrZone.bakarLemak:
        return const Color(0xFF4DE1A1); // hijau/teal (senada aksen app)
      case HrZone.aerobik:
        return const Color(0xFFE1D24D); // kuning
      case HrZone.anaerobik:
        return const Color(0xFFE1974D); // oranye
      case HrZone.maksimal:
        return const Color(0xFFE14D4D); // merah
    }
  }
}

/// Data biometrik user, dipakai untuk menentukan Max HR & zona.
///
/// Catatan penting: rumus zona detak jantung yang akurat secara fisiologis
/// berbasis USIA (Max HR ≈ 208 − 0.7×usia — formula Tanaka), bukan tinggi
/// atau berat badan. Tinggi & berat badan disimpan sesuai permintaan (dan
/// berguna untuk fitur turunan seperti estimasi kalori/BMI di masa depan),
/// namun kolom Usia ditambahkan sebagai penentu utama Max HR agar zona yang
/// dihasilkan valid.
class HeartRateProfile {
  const HeartRateProfile({this.ageYears, this.heightCm, this.weightKg});

  final int? ageYears;
  final double? heightCm;
  final double? weightKg;

  int get maxHr {
    final age = ageYears ?? 30;
    return (208 - 0.7 * age).round();
  }

  HrZone zoneFor(int bpm) {
    if (bpm <= 0) return HrZone.istirahat;
    final pct = (bpm / maxHr) * 100;
    if (pct < 50) return HrZone.istirahat;
    if (pct < 60) return HrZone.pemanasan;
    if (pct < 70) return HrZone.bakarLemak;
    if (pct < 80) return HrZone.aerobik;
    if (pct < 90) return HrZone.anaerobik;
    return HrZone.maksimal;
  }

  HeartRateProfile copyWith({
    int? ageYears,
    double? heightCm,
    double? weightKg,
  }) {
    return HeartRateProfile(
      ageYears: ageYears ?? this.ageYears,
      heightCm: heightCm ?? this.heightCm,
      weightKg: weightKg ?? this.weightKg,
    );
  }
}

/// Mengelola scan, koneksi, dan parsing data BLE Heart Rate.
class HeartRateService {
  final _bpmController = StreamController<int>.broadcast();
  final _stateController =
      StreamController<HrConnectionState>.broadcast(sync: true);
  final _deviceNameController = StreamController<String?>.broadcast();

  StreamSubscription<List<int>>? _valueSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  BluetoothDevice? _device;

  HrConnectionState _state = HrConnectionState.disconnected;

  Stream<int> get bpmStream => _bpmController.stream;
  Stream<HrConnectionState> get stateStream => _stateController.stream;
  Stream<String?> get deviceNameStream => _deviceNameController.stream;
  HrConnectionState get state => _state;
  String? get connectedDeviceName => _device?.platformName;

  void _setState(HrConnectionState s) {
    _state = s;
    _stateController.add(s);
  }

  /// Minta izin runtime yang dibutuhkan BLE di Android (12+ & lama).
  Future<bool> requestPermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    return statuses.values.every(
      (s) => s.isGranted || s.isLimited || s.isDenied == false,
    );
  }

  /// Mulai scan device yang broadcast Heart Rate Service (0x180D).
  /// Hasil scan didengarkan lewat [FlutterBluePlus.scanResults].
  Future<void> startScan() async {
    await requestPermissions();
    _setState(HrConnectionState.scanning);
    try {
      await FlutterBluePlus.startScan(
        withServices: [heartRateServiceUuid],
        timeout: const Duration(seconds: 10),
      );
    } catch (_) {
      // Biarkan UI tetap responsif; user bisa coba scan lagi.
    }
    if (_state == HrConnectionState.scanning) {
      _setState(HrConnectionState.disconnected);
    }
  }

  Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
  }

  Future<void> connect(BluetoothDevice device) async {
    await stopScan();
    _setState(HrConnectionState.connecting);
    _device = device;
    _deviceNameController.add(device.platformName);

    _connSub?.cancel();
    _connSub = device.connectionState.listen((connState) {
      if (connState == BluetoothConnectionState.disconnected) {
        _setState(HrConnectionState.disconnected);
        _bpmController.add(0);
      }
    });

    try {
      // flutter_blue_plus versi 2.x mewajibkan parameter `license` untuk
      // kepatuhan lisensi mereka. `License.nonprofit` berlaku untuk
      // penggunaan personal/nonprofit/edukasi (gratis, tanpa perlu beli
      // lisensi). Jika app ini nanti dirilis untuk tujuan komersial oleh
      // organisasi for-profit, ganti ke `License.commercial` dan beli
      // lisensi resminya — lihat https://pub.dev/packages/flutter_blue_plus/license
      await device.connect(
        timeout: const Duration(seconds: 12),
        license: License.nonprofit,
      );
      final services = await device.discoverServices();
      for (final service in services) {
        if (service.uuid == heartRateServiceUuid) {
          for (final characteristic in service.characteristics) {
            if (characteristic.uuid == heartRateMeasurementUuid) {
              await characteristic.setNotifyValue(true);
              _valueSub?.cancel();
              _valueSub = characteristic.onValueReceived.listen(_onHrData);
              device.cancelWhenDisconnected(_valueSub!);
            }
          }
        }
      }
      _setState(HrConnectionState.connected);
    } catch (_) {
      _setState(HrConnectionState.disconnected);
    }
  }

  void _onHrData(List<int> data) {
    if (data.isEmpty) return;
    final flags = data[0];
    final is16bit = (flags & 0x01) != 0;
    final bpm = is16bit ? (data[1] | (data[2] << 8)) : data[1];
    _bpmController.add(bpm);
  }

  Future<void> disconnect() async {
    await _device?.disconnect();
    _valueSub?.cancel();
    _device = null;
    _setState(HrConnectionState.disconnected);
    _bpmController.add(0);
    _deviceNameController.add(null);
  }

  void dispose() {
    _valueSub?.cancel();
    _connSub?.cancel();
    _bpmController.close();
    _stateController.close();
    _deviceNameController.close();
  }
}

// ============================================================================
// UI: Bar heart rate — ditempatkan tepat di bawah speedometer.
// ============================================================================
class HeartRateBar extends StatelessWidget {
  const HeartRateBar({
    super.key,
    required this.bpm,
    required this.zone,
    required this.darkUi,
    required this.onTap,
  });

  final int bpm;
  final HrZone zone;
  final bool darkUi;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hasSignal = bpm > 0;
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          color: darkUi ? Colors.white.withOpacity(0.06) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color:
                darkUi ? Colors.white.withOpacity(0.09) : Colors.black.withOpacity(0.08),
          ),
        ),
        child: Row(
          children: [
            // Ikon hati + BPM selalu merah, sesuai permintaan.
            _HeartbeatIcon(active: hasSignal),
            const SizedBox(width: 10),
            Text(
              hasSignal ? '$bpm' : '--',
              style: const TextStyle(
                color: Color(0xFFE14D4D),
                fontSize: 26,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              'bpm',
              style: TextStyle(
                color: darkUi ? Colors.white54 : Colors.black45,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            // Chip indikator zona — warna berbeda per level intensitas.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: zone.color.withOpacity(0.16),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: zone.color.withOpacity(0.55)),
              ),
              child: Text(
                hasSignal ? zone.label : 'Belum terhubung',
                style: TextStyle(
                  color: zone.color,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right,
              color: darkUi ? Colors.white30 : Colors.black26,
            ),
          ],
        ),
      ),
    );
  }
}

class _HeartbeatIcon extends StatefulWidget {
  const _HeartbeatIcon({required this.active});
  final bool active;

  @override
  State<_HeartbeatIcon> createState() => _HeartbeatIconState();
}

class _HeartbeatIconState extends State<_HeartbeatIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  @override
  void didUpdateWidget(covariant _HeartbeatIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active) {
      _controller.repeat(reverse: true);
    } else {
      _controller.stop();
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.active) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: Tween(begin: 1.0, end: widget.active ? 1.18 : 1.0)
          .animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut)),
      child: const Icon(Icons.favorite, color: Color(0xFFE14D4D), size: 28),
    );
  }
}

// ============================================================================
// UI: Bottom sheet pairing device + form biometrik (usia/tinggi/berat).
// ============================================================================
Future<void> showHeartRatePairingSheet({
  required BuildContext context,
  required HeartRateService service,
  required HeartRateProfile profile,
  required ValueChanged<HeartRateProfile> onProfileSaved,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _HeartRatePairingSheet(
      service: service,
      profile: profile,
      onProfileSaved: onProfileSaved,
    ),
  );
}

class _HeartRatePairingSheet extends StatefulWidget {
  const _HeartRatePairingSheet({
    required this.service,
    required this.profile,
    required this.onProfileSaved,
  });

  final HeartRateService service;
  final HeartRateProfile profile;
  final ValueChanged<HeartRateProfile> onProfileSaved;

  @override
  State<_HeartRatePairingSheet> createState() => _HeartRatePairingSheetState();
}

class _HeartRatePairingSheetState extends State<_HeartRatePairingSheet> {
  late final TextEditingController _ageCtrl =
      TextEditingController(text: widget.profile.ageYears?.toString() ?? '');
  late final TextEditingController _heightCtrl =
      TextEditingController(text: widget.profile.heightCm?.toStringAsFixed(0) ?? '');
  late final TextEditingController _weightCtrl =
      TextEditingController(text: widget.profile.weightKg?.toStringAsFixed(0) ?? '');

  List<ScanResult> _results = [];
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<HrConnectionState>? _stateSub;
  HrConnectionState _connState = HrConnectionState.disconnected;

  @override
  void initState() {
    super.initState();
    _connState = widget.service.state;
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      if (!mounted) return;
      setState(() => _results = results);
    });
    _stateSub = widget.service.stateStream.listen((s) {
      if (!mounted) return;
      setState(() => _connState = s);
    });
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _stateSub?.cancel();
    _ageCtrl.dispose();
    _heightCtrl.dispose();
    _weightCtrl.dispose();
    super.dispose();
  }

  void _saveProfile() {
    widget.onProfileSaved(
      HeartRateProfile(
        ageYears: int.tryParse(_ageCtrl.text),
        heightCm: double.tryParse(_heightCtrl.text),
        weightKg: double.tryParse(_weightCtrl.text),
      ),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Data biometrik disimpan')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final darkUi = Theme.of(context).brightness == Brightness.dark;
    final bg = darkUi ? const Color(0xFF0D1721) : const Color(0xFFF7FAF8);

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: bg,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: darkUi ? Colors.white24 : Colors.black12,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  const Icon(Icons.favorite, color: Color(0xFFE14D4D)),
                  const SizedBox(width: 8),
                  Text(
                    'Heart Rate Monitor',
                    style: TextStyle(
                      color: darkUi ? Colors.white : Colors.black87,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),

              // --- Status koneksi & tombol scan/disconnect ---
              _SectionLabel('PAIRING DEVICE', darkUi: darkUi),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      switch (_connState) {
                        HrConnectionState.connected =>
                          'Terhubung: ${widget.service.connectedDeviceName ?? "-"}',
                        HrConnectionState.connecting => 'Menghubungkan...',
                        HrConnectionState.scanning => 'Mencari device...',
                        HrConnectionState.disconnected => 'Belum terhubung',
                      },
                      style: TextStyle(
                        color: darkUi ? Colors.white70 : Colors.black54,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  if (_connState == HrConnectionState.connected)
                    TextButton(
                      onPressed: () => widget.service.disconnect(),
                      child: const Text('Putuskan'),
                    )
                  else
                    FilledButton.icon(
                      onPressed: _connState == HrConnectionState.scanning
                          ? null
                          : () => widget.service.startScan(),
                      icon: const Icon(Icons.bluetooth_searching, size: 18),
                      label: Text(
                        _connState == HrConnectionState.scanning ? 'Scanning' : 'Scan',
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              ..._results.map((r) {
                final name = r.device.platformName.isEmpty
                    ? r.device.remoteId.str
                    : r.device.platformName;
                return Card(
                  color: darkUi ? Colors.white.withOpacity(0.05) : Colors.white,
                  child: ListTile(
                    leading: const Icon(Icons.watch),
                    title: Text(name, style: TextStyle(color: darkUi ? Colors.white : Colors.black87)),
                    subtitle: Text('RSSI: ${r.rssi}'),
                    trailing: FilledButton(
                      onPressed: () => widget.service.connect(r.device),
                      child: const Text('Hubungkan'),
                    ),
                  ),
                );
              }),

              const SizedBox(height: 24),

              // --- Form biometrik untuk penentuan zona ---
              _SectionLabel('DATA UNTUK ZONA HEART RATE', darkUi: darkUi),
              const SizedBox(height: 6),
              Text(
                'Usia dipakai untuk menghitung Max HR (208 − 0.7×usia). '
                'Tinggi & berat tersimpan untuk fitur tambahan (mis. estimasi kalori).',
                style: TextStyle(
                  color: darkUi ? Colors.white38 : Colors.black38,
                  fontSize: 11.5,
                ),
              ),
              const SizedBox(height: 12),
              _NumberField(controller: _ageCtrl, label: 'Usia (tahun)', darkUi: darkUi),
              const SizedBox(height: 10),
              _NumberField(controller: _heightCtrl, label: 'Tinggi badan (cm)', darkUi: darkUi),
              const SizedBox(height: 10),
              _NumberField(controller: _weightCtrl, label: 'Berat badan (kg)', darkUi: darkUi),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _saveProfile,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('Simpan'),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, {required this.darkUi});
  final String text;
  final bool darkUi;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: darkUi ? Colors.white54 : Colors.black45,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.0,
      ),
    );
  }
}

class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.controller,
    required this.label,
    required this.darkUi,
  });

  final TextEditingController controller;
  final String label;
  final bool darkUi;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      style: TextStyle(color: darkUi ? Colors.white : Colors.black87),
      decoration: InputDecoration(
        labelText: label,
        filled: true,
        fillColor: darkUi ? Colors.white.withOpacity(0.05) : Colors.black.withOpacity(0.03),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}
