# IOT dashboard

Real-time telemetry, GPS tracking, forecasting, and MJPEG camera monitoring in a Flutter mobile app.

## 1. Project Title

**IoT Mobile Dashboard**

## 2. Project Overview

IoT Mobile Dashboard is a Flutter application that visualizes live sensor data received over MQTT. It combines telemetry, GPS position tracking, anomaly detection, forecasts, and camera feeds into a single mobile interface.

The project appears to be built for operators or engineers who need a compact way to monitor a remote device or vehicle in real time. Its main objective is to turn streamed sensor payloads into readable dashboard cards, charts, forecasts, and logs.

This repository is currently mobile-focused.

## 3. Features

### Live telemetry dashboard

- Displays speed, pitch, roll, yaw, and acceleration values from incoming MQTT messages.
- Highlights anomalies when readings move outside the expected range.

### GPS and map view

- Shows the latest GPS position on an interactive OpenStreetMap map.
- Keeps a short trail of recent GPS points.
- Projects a short forecast path using a Kalman filter.

### Forecasting and anomaly detection

- Uses Holt-style double exponential smoothing for sensor forecasting.
- Uses rolling statistics and z-scores to flag anomalous readings.
- Shows 10-step forecasts for telemetry values.

### Camera monitoring

- Displays an MJPEG camera stream inside the app.
- Supports switching between up to three camera URLs received from MQTT.
- Attempts mDNS resolution for camera URLs ending in `.local`.

### Data logging and export

- Keeps recent sensor records in memory for the current session.
- Exports the log as CSV to the app documents directory.
- Shows the exported file path in-app after saving.

### Connection control

- Shows MQTT connection status in the top bar.
- Lets the user disconnect and reconnect from the dashboard.

## 4. Screen

Dashboard Screen


Graphs Screen


Forecast Screen


Logs Screen


## 5. Tech Stack

| Technology | Purpose |
| --- | --- |
| Flutter | Cross-platform UI framework |
| Dart | Application language |
| Material 3 | App theming and widgets |
| MQTT | Receives live telemetry from a broker |
| OpenStreetMap via `flutter_map` | Map rendering |
| `mjpeg_view` | Displays camera streams |
| `multicast_dns` | Resolves `.local` camera hostnames |
| `path_provider` | Writes exported CSV files to the app documents directory |
| `latlong2` | Represents map coordinates and GPS points |
| Custom state with `StatefulWidget`, `ValueNotifier`, and `AnimationController` | App state and UI updates |

The project does not use Firebase, a database, or a dedicated external state-management package such as Provider, Bloc, or Riverpod.

## 6. Project Structure

| Path | Purpose |
| --- | --- |
| `lib/main.dart` | Main application entry point and all runtime logic, including UI, MQTT handling, forecasting, GPS mapping, and export logic |
| `assets/fonts/` | Bundled fonts used by the UI |
| `android/` | Android application configuration and permissions |
| `test/` | Flutter widget test |

The current source keeps the app logic largely in `lib/main.dart` instead of splitting it into multiple feature folders.

## 7. Installation

### Requirements

- Flutter SDK compatible with Dart `^3.11.0`
- Android Studio or VS Code with Flutter and Dart extensions
- Android SDK for Android builds

### Clone the repository

```bash
git clone <repository-url>
cd <repository-folder>
```

### Install dependencies

```bash
flutter pub get
```

### Verify the environment

```bash
flutter doctor
```

### Run the app

```bash
flutter run
```

## 8. Configuration

No API keys, environment variables, Firebase setup, or local database setup are required in the current source.

Before running the app, make sure the following are true:

- The device has internet access.
- The MQTT broker configured in `lib/main.dart` is reachable.
- The incoming payload is published on the expected topic.
- Any camera URLs in the MQTT payload are valid MJPEG stream URLs.

### MQTT configuration used by the app

The app currently connects to a public MQTT broker and subscribes to a single telemetry topic.

```text
Broker: broker.hivemq.com
Port: 1883
Topic: myproject/sensors/all
```

### Expected payload shape

The code expects a JSON payload with these top-level groups:

```json
{
	"gps": {
		"lat": 23.2156,
		"lng": 72.6369,
		"speed": 42.0
	},
	"orientation": {
		"pitch": 1.2,
		"roll": -0.4,
		"yaw": 178.5
	},
	"acceleration": {
		"ax": 0.01,
		"ay": 0.02,
		"az": 9.81
	},
	"cameras": {
		"cam1": { "url": "http://example.com/stream" },
		"cam2": { "url": "http://example.com/stream" },
		"cam3": { "url": "http://example.com/stream" }
	}
}
```

If your publisher uses a different schema, you must update `lib/main.dart` accordingly.

## 9. How to Run

### Debug mode

```bash
flutter run
```

### Release mode

```bash
flutter run --release
```

### Android

```bash
flutter devices
flutter run -d <android-device-id>
```


## 10. How the Application Works

1. The app starts in `IoTMobileApp` and opens `SensorDashboard`.
2. On startup, the app connects to the MQTT broker and subscribes to the telemetry topic.
3. Each received JSON message updates the live readings, GPS position, camera URLs, anomaly flags, and rolling in-memory log.
4. The dashboard is organized into four tabs:
	 - Dashboard: live metrics, map, and camera preview
	 - Graphs: historical charts and forecast curves
	 - Forecast: 10-step sensor forecasts, anomaly status, and GPS projection
	 - Logs: session log table and export controls
5. Sensor values are analyzed with forecasting and anomaly-detection helpers before being rendered.
6. CSV export writes the current session log to the app documents directory.

### Data flow

- MQTT message in
- JSON parsing
- UI state update
- Forecast/anomaly calculation
- Map and camera refresh
- Optional CSV export

### Backend and storage

- There is no REST backend, authentication layer, or database in the repository.
- Session logs live in memory only until the app is closed.
- Exported data is saved as a CSV file on the device.

## 11. Dependencies

| Package | Purpose |
| --- | --- |
| `flutter_map` | Renders the GPS map and markers |
| `latlong2` | Provides coordinate objects for map positions and forecasts |
| `mqtt_client` | Connects to the MQTT broker and subscribes to sensor updates |
| `multicast_dns` | Resolves `.local` camera hostnames to IP addresses |
| `path_provider` | Finds the app documents directory for CSV export |
| `mjpeg_view` | Displays live MJPEG camera feeds |

`cupertino_icons` is declared in `pubspec.yaml`, but the current source does not reference it directly.

## 12. Assets

The project currently bundles only fonts under `assets/fonts/`:

- `Manrope-Regular.ttf`
- `Manrope-Bold.ttf`
- `JetBrainsMono-Regular.ttf`

These fonts are used for the app's dashboard typography and numeric readouts.

No local image, icon, or JSON asset files are used by the current source. Map tiles and camera streams are loaded from network sources instead of bundled assets.

## 13. Permissions

| Permission | Where it is used | Why it is required |
| --- | --- | --- |
| `INTERNET` | Android manifest | Required for MQTT connectivity, map tiles, and MJPEG camera streams |

Additional notes:

- The app does not request device camera permission because it shows network camera streams, not the phone camera.
- The app does not request location permission because GPS data comes from MQTT, not from the device's location services.
- The app does not request storage permission because CSV export uses the app documents directory through `path_provider`.
- Android cleartext traffic is enabled in the manifest because the current MQTT connection uses port `1883` and some camera feeds may be plain HTTP.

## 14. Build Instructions

### APK

```bash
flutter build apk --release
```

### App Bundle

```bash
flutter build appbundle --release
```

## 15. Troubleshooting

### MQTT connection does not come online

- Confirm the device has internet access.
- Confirm the broker host and port in `lib/main.dart` are reachable.
- Confirm the publisher is sending data to `myproject/sensors/all`.
- If the broker is blocked by your network, the app will remain offline.

### Dashboard shows no live readings

- The app waits for MQTT messages before the graphs and forecast panels become useful.
- The forecast view needs at least five readings before it can start forecasting.

### Camera feed stays blank

- Confirm the MQTT payload includes a valid camera URL.
- If the URL uses `.local`, ensure mDNS resolution works on the network.
- Confirm the stream is actually MJPEG and accessible from the device.

### Map tiles do not load

- Confirm the device has internet access.
- The map depends on OpenStreetMap tiles.

### Exported CSV is not easy to find

- The CSV is saved to the app documents directory.
- Use the snackbar message to find the exact file path.
- Copy the file from the device's app storage if you need to move it elsewhere.

## 16. Testing

Run the available Flutter test with:

```bash
flutter test
```

The repository currently includes a basic smoke test for the app shell.

## 17. License

This project currently does not specify a license.

