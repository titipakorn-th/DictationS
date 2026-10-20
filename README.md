# DictationS

<p align="center">
  <img src="packaging/AppIcon.png" alt="DictationS app icon" width="128">
</p>

DictationS is a macOS push-to-talk dictation app. Hold **Fn** while you speak. Release it to transcribe your speech locally and type the result into the focused app.

## Features

- Runs Qwen3-ASR 0.6B or NVIDIA Parakeet TDT v3 with the project's pure-Rust CPU inference crate at [`crates/qwen-asr`](crates/qwen-asr/) and the [`parakeet-rs`](https://github.com/altunenes/parakeet-rs) crate.
- Shows recording, transcription, model loading, and download progress in a status island at the bottom center of the screen.
- Shows live microphone levels while recording and transcription time after dictation.
- Lets you switch or remove downloaded models from the menu bar without restarting the app.
- Shows the app version in the menu bar and checks the GitHub release feed for a newer version.

## Install

Download the [latest DictationS release](https://github.com/titipakorn-th/DictationS/releases/latest) and open its `.dmg` file. Drag `DictationS.app` into the `Applications` shortcut in the disk image.

The current release targets Apple Silicon. This first release is ad hoc signed and not notarized, so macOS may warn before opening it.

To build and install from source, install Rust and the Xcode Command Line Tools, then run:

```sh
./scripts/install-macos.sh
```

The script builds and copies the app to `/Applications/DictationS.app`. Launch it from Applications or run:

```sh
open /Applications/DictationS.app
```

The first model download requires an internet connection.

## Grant permissions

Enable **DictationS** under **System Settings > Privacy & Security > Accessibility**. Restart the app after granting access. DictationS needs Accessibility access to detect **Fn** and type the transcript.

The first time you hold **Fn**, macOS asks for Microphone access. Allow it so DictationS can record speech.

## Choose and manage a model

The default model is Qwen3-ASR 0.6B. DictationS downloads the selected model if its files are missing, at startup or when you select it. The [Qwen3-ASR 0.6B](https://huggingface.co/Qwen/Qwen3-ASR-0.6B) checkpoint is hosted by Qwen on Hugging Face, and the [Parakeet TDT v3](https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx) checkpoint is the ONNX export of NVIDIA's [Parakeet TDT v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3).

Parakeet TDT v3 is multilingual and detects the language on its own, and it punctuates and capitalises its output. It runs on ONNX Runtime on the CPU, and DictationS downloads its int8 export, which is about 640 MB against 1.8 GB for Qwen3-ASR 0.6B.

Open **Speech Model** in the menu bar. Each model has a submenu with **Use this model** and **Remove downloaded model** actions. Your selection is saved for later launches. The menu indicates whether each model is downloaded. The status island shows download progress.

Models are stored under `~/Library/Application Support/DictationS/models/`. DictationS migrates existing data from `~/Library/Application Support/Dictations` on launch and preserves files already in the new location. Removing the selected model unloads it and leaves DictationS open without a model. Choose a model again to download it.

Set `DICTATIONS_MODEL_DIR` to load a ready model from a custom directory. This disables automatic model downloads.

## Audio and privacy

DictationS captures audio while you hold **Fn**. It keeps samples in memory, writes a temporary WAV file for inference, and removes that file after transcription. Speech recognition runs locally on your Mac. The transcript is typed into the app that has focus.

## Build

The app version lives in `Cargo.toml`. The packaging scripts copy it into the app bundle and into the disk image name, and the menu bar shows it next to **Check for Updates…**.

To build the app bundle without installing it, run:

```sh
./scripts/package-macos.sh
```

The script writes `target/DictationS.app` and includes the icon from `packaging/AppIcon.png` in the bundle as `DictationS.icns`.

To create a compressed disk image, run:

```sh
./scripts/package-dmg.sh
```

The script writes `target/DictationS-<version>.dmg`, using the version from `Cargo.toml` unless you pass one. Publish it as a GitHub release tagged `v<version>` so **Check for Updates…** finds it.

To transcribe a WAV file with a downloaded model, run:

```sh
cargo run --release --example transcribe -- parakeet-tdt-v3 recording.wav
```
