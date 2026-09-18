# ⏱️ Timeler

> **Atmospheric focus & Pomodoro productivity timer with dynamic weather and ocean transitions.**

[![Get it from the Snap Store](https://snapcraft.io/static/images/badges/en/snap-store-black.svg)](https://snapcraft.io/timeler)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Linux-orange.svg)]()

---

## 🌊 Atmospheric Transitions

Timeler is designed to ground your focus through living environments that transform as your session progresses:

- ⛈️ **Storm to Clear Sky**: Rain and dark thunderclouds gradually disperse into bright, sunlit horizons.
- 🌌 **Night to Dawn**: Deep starry midnight slowly warms into a glowing golden sunrise.
- 🌊 **Deep Ocean to Surface Water**: Rise from abyssal bioluminescent depths through shimmering bubbles to sun-drenched turquoise shallows.

---

## 🚀 Installation

### Snap Store (Universal Linux)

Timeler is officially available on Canonical's Snap Store for Ubuntu, Debian, Fedora, Arch, and all snap-supported distributions:

```bash
sudo snap install timeler
```

Or open the **Ubuntu Software Center / Snap Store** app and search for **`timeler`**.

### Debian / Ubuntu (`.deb`)

Download the latest `.deb` package from our [Releases](https://github.com/atharva2012tiwari/timeler/releases) page, then install via:

```bash
sudo dpkg -i timeler_1.1.0_amd64.deb
```

### Fedora / RHEL / openSUSE (`.rpm`)

Download the latest `.rpm` package from our [Releases](https://github.com/atharva2012tiwari/timeler/releases) page, then install via:

```bash
sudo dnf install ./timeler-1.1.0-1.x86_64.rpm
```

---

## ✨ Features

- **Redesigned 3-Option Pomodoro Experience**: Direct, luxury glassmorphic cards for Focus, Short Break, and Long Break with quick steppers and round tracking.
- **Step-by-Step Chime & Continue Flow**: Bell chime alerts when sessions finish, with smooth guided transitions to breaks and subsequent rounds.
- **Precision Wheel Timer Picker**: Tactile drum-wheel picker with hours, minutes, and seconds selection.
- **Focus Progress & Analytics**: Daily, weekly (with 7-day visualizer), monthly, and all-time productivity tracking and session history.
- **Physics-Driven Particles**: Real-time canvas particle engines for rising bubbles and atmospheric rain.
- **Glassmorphic UI**: Clean, distraction-free frosted interface with adaptive theme colors.
- **Task Management**: Integrated inline focus task checklist.
- **Audio Feedback**: Native Linux audio alerts on session completion and round changes.

---

## 🛠️ Development

Built with [Flutter](https://flutter.dev) for Linux desktop.

```bash
# Clone the repository
git clone https://github.com/atharva2012tiwari/timeler.git
cd timeler

# Fetch dependencies
flutter pub get

# Run on Linux desktop
flutter run -d linux

# Build release bundle
flutter build linux --release
```

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
