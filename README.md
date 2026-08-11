# CameraCoach 📸✨

An iPhone camera app with a live AI photography coach. Point the camera at your scene and get real-time, glanceable guidance — a rule-of-thirds grid, a level indicator, an aesthetics score, directional arrows, and short natural-language tips like *"Move a little right to center your subject"* — before you press the shutter.

Built with SwiftUI, AVFoundation, the Vision framework, and your choice of AI backend.

## How it works

CameraCoach analyzes your viewfinder in two layers:

**Layer 1 — on-device vision (always on).** Every few frames, Apple's Vision framework computes an aesthetics score, horizon tilt, subject position (saliency), and face quality — rendered as a grid overlay, a level line that turns yellow when you're level, a subject indicator, a score badge, and directional guidance arrows. No network, no cost, works on any supported iPhone.

**Layer 2 — AI coaching (optional, you choose the brain).** On a throttle, the frame measurements (and, only with your permission, a small face-blurred copy of the frame itself) go to an AI model that writes one short coaching tip. Two backends:

- **Apple Intelligence** — fully on-device via Apple's Foundation Models. Free and private. Requires iPhone 15 Pro or newer with Apple Intelligence enabled.
- **Other AI models** — any provider speaking the industry-standard chat-completions API: OpenAI, Anthropic Claude, Google Gemini, Azure AI Foundry, OpenRouter, or a local model on your Mac via Ollama / LM Studio (free and private, works with any iPhone).

## Features

- Full camera app: native-resolution photos, Live Photos, video recording with audio, front/back cameras, flash, tap-to-focus with exposure slider, pinch/preset zoom
- Live composition overlay: rule-of-thirds grid, level indicator, subject tracker, aesthetics score, directional guidance arrows
- AI coaching with selectable backend, detail level (brief tip vs. 2–3 sentence critique), and 20+ languages
- Session gallery with photo viewing, video playback, and deletion (removes from your photo library too, with iOS confirmation)
- AI usage controls: request throttling, pixel-level motion detection (a static scene sends nothing), live request/token readout, all-time usage stats, auto-pause during playback/settings, auto-off after 5 minutes of video recording
- Privacy by design: one-time consent before any frame leaves the phone, on-screen upload indicator, on-device face blurring before upload, EXIF/location stripping, API keys in the hardware Keychain, HTTPS enforced for non-local servers

## Requirements

- **Xcode 26 or newer** on a Mac
- **An iPhone running iOS 26 or newer.** Any supported iPhone gets the full camera + overlay + cloud/local AI coaching; Apple Intelligence coaching additionally needs an iPhone 15 Pro or newer.
- **A free Apple ID** for code signing (no paid developer account needed)
- For AI coaching: either Apple Intelligence, an API key from a model provider, or Ollama/LM Studio running on a computer on your Wi-Fi

## Install on your iPhone

1. **Clone and open:**
   ```bash
   git clone https://github.com/zhangluhui/CameraCoach.git
   cd CameraCoach
   open CameraCoach.xcodeproj
   ```

2. **Set your signing team:** in Xcode, select the blue `CameraCoach` project icon → `CameraCoach` target → *Signing & Capabilities* → check "Automatically manage signing" → pick your Apple ID under Team ("Add an Account…" if needed).

3. **Connect your iPhone** with a cable, unlock it, and tap *Trust* if prompted. First time only: enable Developer Mode on the phone (Settings → Privacy & Security → Developer Mode → on, phone restarts).

4. **Select your iPhone** as the run destination in Xcode's toolbar and press **⌘R**. If iOS blocks the first launch with an "Untrusted Developer" message: on the phone, Settings → General → VPN & Device Management → trust your certificate, then run again.

5. **Grant permissions** on first use: camera (required), photo library add (to save shots), microphone (only for video).

> Free-Apple-ID builds expire after 7 days — just press ⌘R again to reinstall. After the first cable run you can deploy over Wi-Fi.

## Using the app

On launch, pick your coaching backend:

- **Apple Intelligence** — tap Start Camera. Done.
- **Other AI models** — enter a base URL, model name, and API key. Examples:
  | Provider | Base URL | Model example |
  |---|---|---|
  | OpenAI | `https://api.openai.com/v1` | `gpt-5.6-luna` |
  | Anthropic | `https://api.anthropic.com/v1` | `claude-sonnet-5` |
  | Azure AI Foundry | `https://<resource>.openai.azure.com/openai/v1` | your deployment name |
  | Ollama (local) | `http://<your-mac-ip>:11434/v1` | `llama3.2` |

  For "AI sees photo" mode, pick a vision-capable model. Local servers need no API key; run Ollama with `OLLAMA_HOST=0.0.0.0 ollama serve` so the phone can reach it.

In the camera: tap **AI Coach** to expand the coaching controls and switch the coach on. The eye button controls whether frames are shared with the model or measurements only. The gear opens settings anytime — language, detail level, and usage stats live there.

## Token Usage

Apple Intelligence and local models are free. For cloud models, the app is deliberately frugal: coaching is off until you switch it on, requests fire at most every 5 seconds and only when the scene actually changes (a phone on a desk sends nothing), and coaching pauses during playback and settings. A live counter shows requests and tokens while you shoot, and settings keeps an all-time total you can reset.

## Privacy

Everything is opt-in and visible: nothing leaves your phone unless you enable frame sharing, a one-time dialog explains exactly what's sent, an orange indicator lights during every upload, faces are blurred on-device before any frame is uploaded, and re-rendering strips all EXIF/location metadata. API keys live in the device Keychain (unlock-gated, never synced). The app itself stores nothing outside your device; your model provider's retention policy applies to what you choose to send.

## Author

Luhui Zhang — [github.com/zhangluhui](https://github.com/zhangluhui/)

Contributions and issues welcome.
