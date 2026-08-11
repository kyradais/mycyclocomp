import 'dart:convert';
import 'dart:io';

import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'heart_rate_monitor.dart';

/// Snapshot sesi trip yang sedang berjalan, disimpan saat app di-close agar
/// bisa dilanjutkan saat app dibuka kembali.
class TripSession {
  const TripSession({
    required this.stateName,
    required this.distanceMeters,
    required this.duration,
  });

  /// 'idle' | 'running' | 'paused' — disimpan sebagai String agar
  /// storage_service tidak bergantung pada enum di main.dart.
  final String stateName;
  final double distanceMeters;
  final Duration duration;

  factory TripSession.idle() => TripSession(
        stateName: 'idle',
        distanceMeters: 0,
        duration: Duration.zero,
      );

  Map<String, dynamic> toJson() => {
        'state': stateName,
        'distanceMeters': distanceMeters,
        'durationSeconds': duration.inSeconds,
      };

  factory TripSession.fromJson(Map<String, dynamic> json) => TripSession(
        stateName: json['state'] as String? ?? 'idle',
        distanceMeters: (json['distanceMeters'] as num?)?.toDouble() ?? 0,
        duration: Duration(
          seconds: (json['durationSeconds'] as num?)?.toInt() ?? 0,
        ),
      );
}

/// Penyimpanan lokal:
/// - File JSON (documents dir): trail + rute GPX (data titik besar).
/// - SharedPreferences: profil HR + snapshot sesi trip (data kecil).
///
/// Semua method aman-exception (try/catch) supaya tidak merusak app saat
/// storage tidak tersedia (mis. di environment widget test).
class StorageService {
  static Future<String?> _documentsDir() async {
    try {
      return (await getApplicationDocumentsDirectory()).path;
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveTripData(
    List<LatLng> trail,
    List<LatLng> gpx,
    String? gpxName,
  ) async {
    try {
      final dir = await _documentsDir();
      if (dir == null) {
        return;
      }
      final trailJson = trail
          .map((e) => {'lat': e.latitude, 'lng': e.longitude})
          .toList();
      final gpxJson = {
        'name': gpxName,
        'points': gpx.map((e) => {'lat': e.latitude, 'lng': e.longitude}).toList(),
      };
      await File('$dir/trail.json')
          .writeAsString(jsonEncode(trailJson), flush: true);
      await File('$dir/gpx.json').writeAsString(jsonEncode(gpxJson), flush: true);
    } catch (_) {
      // Abaikan — storage tidak tersedia saat ini.
    }
  }

  static Future<(List<LatLng>, List<LatLng>, String?)> loadTripData() async {
    try {
      final dir = await _documentsDir();
      if (dir == null) {
        return (<LatLng>[], <LatLng>[], null);
      }
      var trail = <LatLng>[];
      final trailFile = File('$dir/trail.json');
      if (await trailFile.exists()) {
        trail = (jsonDecode(await trailFile.readAsString()) as List)
            .map((e) => LatLng(
                  ((e as Map)['lat'] as num).toDouble(),
                  (e['lng'] as num).toDouble(),
                ))
            .toList();
      }
      var gpx = <LatLng>[];
      String? gpxName;
      final gpxFile = File('$dir/gpx.json');
      if (await gpxFile.exists()) {
        final data = jsonDecode(await gpxFile.readAsString()) as Map<String, dynamic>;
        gpxName = data['name'] as String?;
        gpx = (data['points'] as List)
            .map((e) => LatLng(
                  ((e as Map)['lat'] as num).toDouble(),
                  (e['lng'] as num).toDouble(),
                ))
            .toList();
      }
      return (trail, gpx, gpxName);
    } catch (_) {
      return (<LatLng>[], <LatLng>[], null);
    }
  }

  static Future<void> saveSession(TripSession session) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('trip_session', jsonEncode(session.toJson()));
    } catch (_) {
      // Abaikan.
    }
  }

  static Future<TripSession> loadSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('trip_session');
      if (raw != null) {
        return TripSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      }
    } catch (_) {
      // Abaikan.
    }
    return TripSession.idle();
  }

  static Future<void> saveHrProfile(HeartRateProfile profile) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('hr_profile', jsonEncode(profile.toMap()));
    } catch (_) {
      // Abaikan.
    }
  }

  static Future<HeartRateProfile?> loadHrProfile() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('hr_profile');
      if (raw == null) {
        return null;
      }
      return HeartRateProfile.fromMap(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveLastBpm(int bpm) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('hr_last_bpm', bpm);
    } catch (_) {
      // Abaikan.
    }
  }

  static Future<int?> loadLastBpm() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt('hr_last_bpm');
    } catch (_) {
      return null;
    }
  }
}
