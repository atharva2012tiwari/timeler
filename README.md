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
sudo dpkg -i timeler_1.0.0_amd64.deb
```

---

## ✨ Features

- **Timer & Pomodoro Modes**: Seamlessly toggle between countdown sessions and Pomodoro cycles with work intervals, short breaks, and long breaks.
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
