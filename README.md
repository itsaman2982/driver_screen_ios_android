# 🚖 DriveScreen: Advanced Fleet "Mission Control" Hub

A professional, high-fidelity driver dashboard application designed for tablet-mounted fleet monitoring. Features real-time multi-channel WebRTC streaming, live hardware telemetry, and a distraction-free "Mission Control" UI for operational efficiency.

---

## 🚀 Key Features

### 📡 Multi-Channel "Hot-Plug" Monitoring
- **Dual-Stream WebRTC**: Synchronous streaming of both **Interior (Front)** and **Road (USB)** camera views directly to the admin panel.
- **Privacy First**: Strictly excludes built-in rear/back cameras; secondary monitoring triggers exclusively upon connection of a genuine external USB device.
- **Auto-Syncing Engine**: Detects hardware changes (connect/disconnect) in real-time and updates the fleet signaling room automatically.

### 📊 "Mission Control" Dashboard
- **Two-Card Operational Hub**: Replaces high-clutter maps with a focused journey dashboard during active rides.
  - **Driver ID**: Verified profile details, vehicle license, and fleet authorization status.
  - **Trip Metrics**: High-visibility Estimated Fare, Live Distance, and ETA counters using premium typography.
- **Live Hardware Telemetry**:
  - 🔋 **Battery Level**: Real-time percentage tracking from the device power supply.
  - 📡 **Connectivity Status**: Dynamic detection of 5G Mobile Data vs. WiFi Active status.
  - 📍 **GPS Localization**: Real-world verification of location service locks.

### 🛡️ Fleet Stability & Security
- **Persistent Session Engine**: Automatic session restoration from shared preferences; the app remembers the driver and active ride state even after backgrounding or restarts.
- **Safety Overlays**: Integrated New Ride Request overlays with haptic and visual alerts.
- **Emergency Ops**: Integrated SOS Breakdown reporting and one-touch Navigation/Support access.

---

## 🛠️ Technical Stack

- **Framework**: Flutter (Dart)
- **Networking**: `socket_io_client`, `dio`, `connectivity_plus`
- **Real-Time Media**: `flutter_webrtc` (H.264/VP8 support)
- **Hardware Abstraction**: `battery_plus`, `geolocator`, `wakelock_plus`
- **Design System**: Vanilla Flutter + `google_fonts` (Outfit/Roboto), `flutter_animate` (Micro-interactions)
- **Map Engine**: `mappls_gl` (used for Idle State navigation)

---

## 📦 Getting Started

### Prerequisites
- Flutter SDK `>=3.2.0`
- Android Studio / VS Code
- A physical Android Tablet (recommended for USB Camera testing)

### Installation
1.  **Clone the Repository**:
    ```bash
    git clone https://github.com/sahilquarecitsolutions/driver_screen.git
    cd driver_screen
    ```
2.  **Install Dependencies**:
    ```bash
    flutter pub get
    ```
3.  **Run the Application**:
    ```bash
    flutter run
    ```

---

## 🏗️ Architecture Overview

The project follows a **Provider-Based State Management** pattern:
- `src/core/providers/driver_provider.dart`: The global state engine handling authentication, socket rooms, and ride lifecycle synchronization.
- `src/features/dashboard/presentation/dashboard_screen.dart`: The primary UI hub with responsive layout logic for both **Landscape (Tablet)** and **Portrait (Mobile)** orientations.
- `src/core/map/mappls_service.dart`: Handles route drawing and traffic-aware navigation overlays.

---

## 🛡️ License

Private Fleet Distribution - All Rights Reserved.
Developed for Sahil Quarec IT Solutions.