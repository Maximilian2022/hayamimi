# Hayamimi Live 🎙️🔴

**Real-Time Multilingual Live Captioning & OBS Subtitles on CPU Only.**

[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![release](https://img.shields.io/badge/release-v1.5.1-emerald.svg)](https://github.com/Maximilian2022/hayamimi-live/releases)
[![platform](https://img.shields.io/badge/platform-Windows%20%7C%20WSL-indigo.svg)](README.md)

[日本語版 README (Japanese)](README.ja.md) / [User Manual](MANUAL.md)

---

## ✨ What is Hayamimi Live?

**Hayamimi Live (早耳 Live)** is an ultra-fast, local, real-time speech-to-text and simultaneous translation subtitle engine designed specifically for streamers, VTubers, and content creators.

No expensive graphics card (GPU) or paid cloud APIs needed. Running entirely on standard PC CPUs, subtitles appear instantly as you speak and finalize roughly **100ms after you stop**, overlaying beautifully on OBS Studio.

```
[ Your Voice (Microphone) ]
       │
       ▼ (Ultra-fast CPU-only local inference)
┌──────────────────────────────────────────────┐
│  Hayamimi Live Engine                        │
│  ├─ High-accuracy Japanese ASR (ReazonSpeech)│
│  └─ Multilingual Translation (FuguMT/M2M-100)│
└──────────────────────────────────────────────┘
       │
       ▼ (OBS Studio Browser Source Overlay)
┌──────────────────────────────────────────────┐
│  Live Subtitles:                             │
│  "Hello! Welcome to today's livestream!"     │
│  ↳ [ZH] 你好！欢迎来到今天的直播！           │
│  ↳ [JA] こんにちは！今日の配信へようこそ！   │
└──────────────────────────────────────────────┘
```

---

## 🔥 Key Highlights

- ⚡ **Ultra-Low Latency (~100ms)**: Subtitles land in real-time as you speak, with final text locked in ~0.1s after you pause.
- 🌐 **Simultaneous Multilingual Translation**: Instantly translate spoken speech into **English, Chinese (Simplified/Traditional), Korean, Spanish, French, German**, and more.
- 🎨 **Stream-Ready Custom Styling**:
  - Pre-loaded with popular Google Fonts (cute rounded, comic, pixel dot, traditional brush, and modern western fonts).
  - Customize main speech and translation lines independently.
  - Choose rich visual effects: crisp outline, TV-style double stroke, or cyber neon glow.
- 🔒 **100% Local, Offline & Private**: Zero cloud dependency, zero external API costs, zero data leakage.

---

## 🚀 Quick Start in 3 Easy Steps

### Step 1: Launch
Double-click **`start.bat`**.  
The desktop launcher will start. Click **"▶ Start Speech Recognition"**.

### Step 2: Add Subtitles to OBS Studio
1. In OBS Studio, click **`+`** under Sources ──▶ **Browser**.
2. Enter **`http://localhost:8833/`** with Width `1920` and Height `1080`.
3. Done! Transparent live subtitles will now overlay on your stream.

### Step 3: Speak & Style
Open **`http://localhost:8833/mic`** in your browser.  
Turn on your microphone and start talking. You can tweak fonts, colors, and translation languages live with instant preview!

---

## 📖 Documentation & Guides

- 🛠️ **Detailed Settings & OBS Setup**: See the full [User Manual (MANUAL.md)](MANUAL.md).
- 🔬 **Upstream Research & Benchmarks**: See the original [Technical Report (ORIGINAL.md)](ORIGINAL.md).

---

## 📄 License

Released under the [MIT License](LICENSE). Free for personal, commercial, and streaming use.
