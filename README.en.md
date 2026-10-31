# Hayamimi Live

A local, CPU-based real-time speech recognition and multilingual translation subtitle system for live streaming.

[日本語版 README](README.md) / [User Manual](MANUAL.en.md) / [Technical Benchmarks & Architecture (ORIGINAL.md)](ORIGINAL.md)

---

## Overview

Hayamimi Live provides real-time speech-to-text and simultaneous translation for live video production and streaming software such as OBS Studio.

All models run locally on the CPU using quantized INT8 weights. Because inference requires neither a dedicated GPU nor external cloud APIs, the system functions entirely offline without telemetry, recurring API costs, or rate limits.

### Key Capabilities

- **Low-Latency CPU Inference**:
  Leverages quantized INT8 ONNX models (ReazonSpeech for Japanese, specialist models for other target languages via sherpa-onnx) to finalize utterances roughly 100ms after speech cessation.
- **Concurrent Multilingual Translation**:
  Simultaneously translates finalized speech into multiple target languages (English via FuguMT CTranslate2, and Chinese, Korean, Spanish, French, German via Meta M2M-100).
- **Customizable Overlay**:
  Provides a transparent browser source overlay with real-time styling controls for fonts, sizing, colors, outlines, and display effects (standard stroke, double outline, glow). Main speech and translation lines can be styled independently.
- **Automated Dictionary Generation from YouTube Archives**:
  Analyzes past stream archives (video, playlist, or channel URLs) to detect proper nouns, game terminology, and speech characteristics, automatically generating phonetic replacement dictionaries to prevent misrecognitions.
- **Local Data Privacy**:
  Audio buffers are processed in-memory and discarded. No audio recordings or transcripts are transmitted to external servers.

---

## Quick Start

### 1. Launch
Run `start.bat` on Windows.  
When the desktop launcher appears, click **"Start Speech Recognition"**.

### 2. Add to OBS Studio
1. Under the **Sources** panel in OBS Studio, add a **Browser** source.
2. Set the URL to `http://localhost:8833/`, Width to `1920`, and Height to `1080`.
3. The transparent subtitle overlay is now active.

### 3. Audio & Style Control
Navigate to `http://localhost:8833/mic` in your browser.  
Select your microphone input, choose target translation languages, and customize subtitle appearance. Changes apply to the OBS overlay immediately.

### 4. Custom Dictionary (Optional)
Navigate to `http://localhost:8833/profile` to generate a personalized replacement dictionary by analyzing your past YouTube stream archives.

---

## Documentation

- **[MANUAL.en.md](MANUAL.en.md)**: Comprehensive user manual covering configuration, font customization, YouTube dictionary builder, and troubleshooting.
- **[ORIGINAL.md](ORIGINAL.md)**: Original technical benchmarks, model comparison reports, and acoustic design rationale.

---

## License

This software is released under the [MIT License](LICENSE). Suitable for personal, commercial, and broadcast use.
