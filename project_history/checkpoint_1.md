# Checkpoint 1 – lib/ Overview

## Project Structure
The **`lib/`** directory contains the core Flutter application logic. It is divided into three main files:

1. **`main.dart`** – Application entry point, UI layout, repository abstraction, and trip state management.
2. **`heart_rate_monitor.dart`** – BLE heart‑rate monitoring, zone calculation, and UI for user biometric profile.
3. **`storage_service.dart` – Local persistence (JSON files + `SharedPreferences`) for trip data, session snapshot, and heart‑rate profile.

---

## 1️⃣ `main.dart`
### Primary responsibilities
- **App bootstrap** (`main()`): ensures widget binding, optionally hides system UI, launches `CyclocompApp`.
- **Theme handling** – Defines light and dark `ThemeData` with a custom color seed and a dark‑map colour matrix.
- **Repository abstraction** – `CyclocompRepository` (interface) and concrete `GeolocatorCyclocompRepository` (provides GPS, compass, and GPX handling). The repository is injected via the widget constructor, enabling testability.
- **Stateful root widget** – `CyclocompApp` creates and disposes the repository depending on ownership.
- **UI composition** – `CyclocompHome` displays:
  - A **FlutterMap** with optional live GPS tracking (`useLiveMap`).
  - Compass overlay (`flutter_compass`).
  - Trip control buttons (Start, Pause/Resume, Stop‑hold).  
  - Metric blocks for distance, speed, altitude, etc.
  - Dark‑UI toggle via `_darkUi` state.
- **Session persistence** – Calls `StorageService.loadSession()` on start and `StorageService.saveSession()` on dispose or state change, allowing the app to restore the last trip state after a cold launch.
- **Heart‑rate integration** – Imports `heart_rate_monitor.dart` and forwards the `HeartRateProfile` to the UI widgets that display current BPM and zone colour.

### Key classes / enums
- `CyclocompApp` (stateful) – top‑level widget controlling theme and repository lifecycle.
- `CyclocompHome` (stateful) – the main screen, handling UI interactions and delegating to the repository for GPS/GPX updates.
- `TripRecordingState` enum – `idle`, `running`, `paused`.
- Various private widgets (`_MetricBlock`, `_MapOverlay`, etc.) that keep UI code modular.

### Notable logic snippets
- Dark‑map colour matrix (`_darkMapMatrix`) – inverts tile colours for better readability on dark UI.
- `_toggleUiTheme` callback – switches between `ThemeMode.dark` and `ThemeMode.light`.
- `onStartTrip`, `onPauseTrip`, `onResumeTrip`, `onStopTrip` – manipulate the repository’s `TripRecordingState` and persist via `StorageService`.

---

## 2️⃣ `heart_rate_monitor.dart`
### Primary responsibilities
- **BLE discovery \u0026 connection** – Uses `flutter_blue_plus` to scan for devices exposing the standard Heart‑Rate Service UUID (`0000180d‑0000‑1000‑8000‑00805f9b34fb`).
- **Permission handling** – Requests Bluetooth and location permissions via `permission_handler`.
- **Data model** – `HeartRateProfile` stores optional `ageYears`, `heightCm`, `weightKg`. It calculates `maxHr` using the Tanaka formula and determines the HR zone (`HrZone`).
- **Zone colour mapping** – `HrZoneX` extension provides human‑readable `label` and colour for each intensity zone (rest, warm‑up, fat‑burn, aerobic, anaerobic, max).
- **UI components** – Widget hierarchy that lets the user:
  - Scan for and connect to a heart‑rate sensor.
  - View live BPM and zone colour.
  - Edit biometric data (age, height, weight) and save it via `StorageService.saveHrProfile`.
- **State management** – `HrConnectionState` enum tracks connection lifecycle (`disconnected`, `scanning`, `connecting`, `connected`).

### Key classes / enums
- `HeartRateProfile` – immutable data class with helper methods (`copyWith`, `toMap`, `fromMap`).
- `HrZone` enum – defines six zones.
- `HrZoneX` extension – label \u0026 colour getters.
- `HeartRateMonitorService` (not fully shown in the excerpt) – contains the scanning/connection logic, subscription to the `heartRateMeasurementUuid` characteristic, and BPM parsing.

### Notable logic snippets
- `maxHr` calculation: `208 - 0.7 * age` (rounded).
- `zoneFor(int bpm)` – maps BPM to a percentage of `maxHr` and returns the appropriate `HrZone`.
- UI form (`_NumberField`) – numeric text fields with dark‑mode styling that feed into the profile.
---

## 3️⃣ `storage_service.dart`
### Primary responsibilities
- **Local file storage** – Writes/reads two JSON files in the app’s documents directory:
  - `trail.json` – list of `{lat, lng}` points representing the recorded route.
  - `gpx.json` – optional GPX metadata (`name` and points).
- **SharedPreferences storage** – Persists small pieces of data that survive app restarts:
  - `TripSession` snapshot (`trip_session`).
  - Heart‑rate profile (`hr_profile`).
  - Last measured BPM (`hr_last_bpm`).
- **Robustness** – All methods wrap I/O in `try/catch` blocks; failures are silently ignored to avoid crashing in test environments.

### Data models
- `TripSession` – Holds `stateName`, `distanceMeters`, `duration`, `avgSpeedKmh`, `maxSpeedKmh`. Provides `toJson` / `fromJson` for serialization.
- `HeartRateProfile` – imported from `heart_rate_monitor.dart`; persisted as a map.

### Key static methods
- `_documentsDir()` – safely resolves the platform‑specific documents directory.
- `saveTripData(List<LatLng> trail, List<LatLng> gpx, String? gpxName)` – writes both JSON files.
- `loadTripData()` – reads the files, returns a tuple `(trail, gpx, gpxName)`.
- `saveSession(TripSession)` / `loadSession()` – SharedPreferences handling.
- `saveHrProfile(HeartRateProfile)` / `loadHrProfile()` – SharedPreferences handling.
- `saveLastBpm(int)` / `loadLastBpm()` – simple integer cache.

---

## Overall Feature Set
| Feature | Implemented in | Description |
|---------|----------------|-------------|
| **App bootstrap & dark/light theme** | `main.dart` | Full‑screen Flutter app with Material3 theming, dark‑mode toggle, and system UI hiding.
| **GPS tracking & map rendering** | `main.dart` (via repository) | Real‑time location updates, map display using `flutter_map`, optional live map mode.
| **Compass overlay** | `main.dart` | Uses `flutter_compass` to show heading.
| **Trip lifecycle (start, pause, resume, stop)** | `main.dart` | Managed via `TripRecordingState`, persisted with `StorageService`.
| **GPX export / trail persistence** | `storage_service.dart` | JSON files store raw trail points; can be later converted to GPX.
| **Heart‑rate sensor integration** | `heart_rate_monitor.dart` | BLE scanning, connection, BPM streaming, zone calculation.
| **User biometric profile (age, height, weight)** | `heart_rate_monitor.dart` + `storage_service.dart` | Stores profile for max‑HR calculation; UI allows editing and saving.
| **Local storage abstraction** | `storage_service.dart` | Handles file I/O and SharedPreferences with graceful error handling.
| **Dark‑map matrix** | `main.dart` | Inverts map tiles for dark UI.

---

## Checkpoint Summary
- All three library files examined and documented.
- Features listed per file with classes, enums, and key methods.
- Markdown checkpoint (`project_history/checkpoint_1.md`) ready for review.

