use std::{
    env,
    error::Error,
    io::Write,
    path::PathBuf,
    process::{ChildStdin, Command, Stdio},
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicBool, Ordering},
        mpsc::{Receiver, RecvTimeoutError, SyncSender, sync_channel},
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

use cpal::{
    SampleFormat, Stream,
    traits::{DeviceTrait, HostTrait, StreamTrait},
};
use enigo::{Enigo, Keyboard, Settings};
use keytap::{Event, EventKind, Key, Tap};
use dictations::{
    engine::{self, Engine},
    model_store::{self, ModelSpec},
};

struct Recording {
    stream: Stream,
    samples: Arc<Mutex<Vec<f32>>>,
    sample_rate: u32,
    level_thread: JoinHandle<()>,
}

#[derive(Default)]
struct State {
    recording: Option<Recording>,
}

fn main() -> Result<(), Box<dyn Error>> {
    let custom_model_dir = env::var_os("DICTATIONS_MODEL_DIR").map(PathBuf::from);
    let selected = selected_model();
    let model = if let Some(spec) = selected {
        show_status("loading", "Loading local speech model…");
        match load_selected_model(spec, custom_model_dir.as_deref(), false) {
            Ok(model) => Some(model),
            Err(error) => {
                show_status(
                    "error",
                    &format!("Could not load {} model: {error}", spec.name),
                );
                return Err(error);
            }
        }
    } else {
        show_status(
            "ready",
            "No speech model selected. Choose a model from the menu.",
        );
        None
    };
    if let Some(spec) = selected {
        show_status(
            "ready",
            &format!("{} model ready. Hold Fn to dictate", spec.name),
        );
        println!("Model: {} (CPU)", spec.name);
    }
    println!("Ready. Hold Fn to record; release Fn to transcribe and type.");

    let state = Arc::new(Mutex::new(State::default()));
    let model = Arc::new(Mutex::new(model));
    let switching = Arc::new(AtomicBool::new(false));
    let dictation_active = Arc::new(AtomicBool::new(false));
    let tap = match Tap::new() {
        Ok(tap) => tap,
        Err(keytap::Error::PermissionDenied) => {
            show_status(
                "error",
                "Enable DictationS in Accessibility, then restart it.",
            );
            return Err("macOS denied keyboard monitoring. Enable DictationS under System Settings > Privacy & Security > Accessibility, then restart.".into());
        }
        Err(error) => {
            show_status(
                "error",
                "Could not start Fn monitoring. Enable Accessibility and restart.",
            );
            return Err(format!("Could not start keyboard monitoring: {error}").into());
        }
    };
    watch_model_settings(
        Arc::clone(&model),
        Arc::clone(&switching),
        Arc::clone(&dictation_active),
        custom_model_dir,
        selected.map(|spec| spec.id.to_owned()),
    );
    for event in tap.iter() {
        handle_event(event, &state, &model, &switching, &dictation_active);
    }
    Ok(())
}

fn load_selected_model(
    spec: &ModelSpec,
    custom_model_dir: Option<&std::path::Path>,
    cancel_if_selection_changes: bool,
) -> Result<Engine, Box<dyn Error>> {
    let models_dir = default_models_dir();
    let model_dir = custom_model_dir
        .map(PathBuf::from)
        .unwrap_or_else(|| model_store::model_directory(&models_dir, spec));
    if custom_model_dir.is_none() && !model_store::is_complete(&model_dir, spec) {
        show_status("downloading", &format!("Downloading {} model…", spec.name));
        model_store::ensure_model(
            spec,
            &model_dir,
            |fraction| {
                let _ = send_island_line(&format!("progress\t{fraction:.3}"));
            },
            || cancel_if_selection_changes && selected_model_id().as_deref() != Some(spec.id),
        )?;
    }
    show_status("loading", &format!("Loading {} model…", spec.name));
    engine::load(spec, &model_dir)
}

fn watch_model_settings(
    model: Arc<Mutex<Option<Engine>>>,
    switching: Arc<AtomicBool>,
    dictation_active: Arc<AtomicBool>,
    custom_model_dir: Option<PathBuf>,
    loaded_size: Option<String>,
) {
    thread::spawn(move || {
        let mut loaded = loaded_size;
        let mut failed: Option<String> = None;
        loop {
            thread::sleep(Duration::from_millis(300));
            let target = selected_model_id();
            if target == loaded {
                failed = None;
                continue;
            }
            let target_key = target.as_deref().unwrap_or("none");
            if failed.as_deref() == Some(target_key) {
                continue;
            }
            if target.is_none() && dictation_active.load(Ordering::Acquire) {
                continue;
            }
            switching.store(true, Ordering::Release);
            let Some(target_id) = target.as_deref() else {
                *model.lock().expect("ASR model poisoned") = None;
                loaded = None;
                failed = None;
                show_status(
                    "ready",
                    "Model removed. Choose a speech model to download it again.",
                );
                switching.store(false, Ordering::Release);
                continue;
            };
            let Some(spec) = model_store::model(target_id) else {
                switching.store(false, Ordering::Release);
                continue;
            };
            show_status("switching", &format!("Switching to {} model…", spec.name));
            match load_selected_model(spec, custom_model_dir.as_deref(), true) {
                Ok(next_model) => {
                    let current = selected_model_id();
                    if current.as_deref() != Some(spec.id) {
                        drop(next_model);
                        switching.store(false, Ordering::Release);
                        continue;
                    }
                    *model.lock().expect("ASR model poisoned") = Some(next_model);
                    loaded = Some(spec.id.to_owned());
                    failed = None;
                    show_status(
                        "ready",
                        &format!("{} model ready. Hold Fn to dictate", spec.name),
                    );
                }
                Err(error) => {
                    let current = selected_model_id();
                    if current.as_deref() == Some(spec.id) {
                        failed = Some(spec.id.to_owned());
                        show_status(
                            "error",
                            &format!("Could not switch to {} model: {error}", spec.name),
                        );
                        eprintln!("Could not switch speech model: {error}");
                    }
                }
            }
            switching.store(false, Ordering::Release);
        }
    });
}

fn selected_model() -> Option<&'static ModelSpec> {
    let mut allowed: Vec<&str> = model_store::MODELS.iter().map(|spec| spec.id).collect();
    allowed.push("none");
    let selection = selected_setting("model-size", &allowed, "0.6b");
    if selection == "none" {
        return None;
    }
    model_store::model(&selection)
}

fn selected_model_id() -> Option<String> {
    selected_model().map(|spec| spec.id.to_owned())
}

fn default_models_dir() -> PathBuf {
    app_support_dir()
        .map(|directory| directory.join("models"))
        .unwrap_or_else(|| PathBuf::from("models"))
}

fn selected_setting(name: &str, allowed: &[&str], default: &str) -> String {
    app_support_dir()
        .map(|directory| directory.join(name))
        .and_then(|path| std::fs::read_to_string(path).ok())
        .map(|value| value.trim().to_owned())
        .filter(|value| allowed.contains(&value.as_str()))
        .unwrap_or_else(|| default.to_owned())
}

fn app_support_dir() -> Option<PathBuf> {
    static DIRECTORY: OnceLock<Option<PathBuf>> = OnceLock::new();
    DIRECTORY
        .get_or_init(|| {
            let support = PathBuf::from(env::var_os("HOME")?).join("Library/Application Support");
            let current = support.join("DictationS");
            let legacy = support.join("Dictations");
            if legacy.exists() {
                if let Err(error) = migrate_directory(&legacy, &current) {
                    eprintln!(
                        "Could not fully migrate {} to {}: {error}",
                        legacy.display(),
                        current.display()
                    );
                }
            }
            Some(current)
        })
        .clone()
}

fn migrate_directory(
    source: &std::path::Path,
    destination: &std::path::Path,
) -> std::io::Result<()> {
    use std::os::unix::fs::MetadataExt;

    if destination.exists() {
        let source_metadata = std::fs::metadata(source)?;
        let destination_metadata = std::fs::metadata(destination)?;
        if source_metadata.dev() == destination_metadata.dev()
            && source_metadata.ino() == destination_metadata.ino()
        {
            return Ok(());
        }
    } else {
        return std::fs::rename(source, destination);
    }
    for entry in std::fs::read_dir(source)? {
        let source_entry = entry?.path();
        let destination_entry = destination.join(source_entry.file_name().unwrap());
        if !destination_entry.exists() {
            std::fs::rename(&source_entry, destination_entry)?;
        } else if source_entry.is_dir() && destination_entry.is_dir() {
            migrate_directory(&source_entry, &destination_entry)?;
        } else if source_entry.is_file() && destination_entry.is_file() {
            let source_metadata = std::fs::metadata(&source_entry)?;
            let destination_metadata = std::fs::metadata(&destination_entry)?;
            if source_metadata.dev() == destination_metadata.dev()
                && source_metadata.ino() == destination_metadata.ino()
            {
                std::fs::remove_file(source_entry)?;
            }
        }
    }
    if std::fs::read_dir(source)?.next().is_none() {
        std::fs::remove_dir(source)?;
    }
    Ok(())
}

fn handle_event(
    event: Event,
    state: &Arc<Mutex<State>>,
    model: &Arc<Mutex<Option<Engine>>>,
    switching: &Arc<AtomicBool>,
    dictation_active: &Arc<AtomicBool>,
) {
    match event.kind {
        EventKind::KeyDown(Key::Function) => {
            if switching.load(Ordering::Acquire) {
                show_status("switching", "Wait for the speech model to finish loading…");
                return;
            }
            dictation_active.store(true, Ordering::Release);
            if selected_model().is_none()
                || model.lock().expect("ASR model poisoned").is_none()
            {
                dictation_active.store(false, Ordering::Release);
                show_status(
                    "ready",
                    "Choose a speech model from the menu before dictating.",
                );
                return;
            }
            let mut state = state.lock().expect("recording state poisoned");
            if state.recording.is_none() {
                match start_recording() {
                    Ok(recording) => {
                        show_status("recording", "Recording… Release Fn to transcribe");
                        println!("Recording…");
                        state.recording = Some(recording);
                    }
                    Err(error) => {
                        dictation_active.store(false, Ordering::Release);
                        show_status(
                            "error",
                            "Could not start the microphone. Check Microphone access.",
                        );
                        eprintln!("Could not start microphone: {error}");
                    }
                }
            }
        }
        EventKind::KeyUp(Key::Function) => {
            let recording = state
                .lock()
                .expect("recording state poisoned")
                .recording
                .take();
            if let Some(recording) = recording {
                show_status("transcribing", "Transcribing locally…");
                let result = transcribe_and_type(recording, model);
                dictation_active.store(false, Ordering::Release);
                if let Err(error) = result {
                    show_status("error", &format!("Dictation failed: {error}"));
                    eprintln!("Dictation failed: {error}");
                }
            }
        }
        _ => {}
    }
}

fn show_status(kind: &str, message: &str) {
    let line = format!("{kind}\t{message}");
    if !send_island_line(&line) {
        eprintln!("DictationS status: {message}");
    }
}

fn send_island_line(line: &str) -> bool {
    static ISLAND: OnceLock<Mutex<Option<ChildStdin>>> = OnceLock::new();
    let stdin = ISLAND.get_or_init(|| {
        let helper = env::current_exe()
            .ok()
            .and_then(|path| path.parent().map(|parent| parent.join("status-island")));
        let stdin = helper.filter(|path| path.is_file()).and_then(|path| {
            Command::new(path)
                .arg(env!("CARGO_PKG_VERSION"))
                .stdin(Stdio::piped())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .ok()
                .and_then(|mut child| child.stdin.take())
        });
        Mutex::new(stdin)
    });
    if let Some(stdin) = stdin.lock().expect("status island input poisoned").as_mut() {
        if writeln!(stdin, "{line}")
            .and_then(|()| stdin.flush())
            .is_ok()
        {
            return true;
        }
    }
    false
}

fn forward_audio_levels(levels: Receiver<f32>) {
    loop {
        let mut level = match levels.recv_timeout(Duration::from_millis(50)) {
            Ok(level) => level,
            Err(RecvTimeoutError::Timeout) => continue,
            Err(RecvTimeoutError::Disconnected) => break,
        };
        while let Ok(latest) = levels.try_recv() {
            level = latest;
        }
        if !send_island_line(&format!("level\t{level:.3}")) {
            break;
        }
    }
}

fn start_recording() -> Result<Recording, Box<dyn Error>> {
    let device = cpal::default_host()
        .default_input_device()
        .ok_or("No microphone input device is available")?;
    let supported = device.default_input_config()?;
    let sample_rate = supported.sample_rate().0;
    let channels = usize::from(supported.channels());
    let config = supported.config();
    let samples = Arc::new(Mutex::new(Vec::new()));
    let (level_tx, level_rx) = sync_channel(1);
    let stream = match supported.sample_format() {
        SampleFormat::F32 => build_stream::<f32>(
            &device,
            &config,
            channels,
            Arc::clone(&samples),
            level_tx,
            |v| v,
        )?,
        SampleFormat::I16 => build_stream::<i16>(
            &device,
            &config,
            channels,
            Arc::clone(&samples),
            level_tx,
            |v| f32::from(v) / f32::from(i16::MAX),
        )?,
        SampleFormat::U16 => build_stream::<u16>(
            &device,
            &config,
            channels,
            Arc::clone(&samples),
            level_tx,
            |v| (f32::from(v) / f32::from(u16::MAX)) * 2.0 - 1.0,
        )?,
        format => return Err(format!("Unsupported microphone sample format: {format:?}").into()),
    };
    stream.play()?;
    let level_thread = thread::Builder::new()
        .name("dictations-mic-meter".into())
        .spawn(move || forward_audio_levels(level_rx))?;
    Ok(Recording {
        stream,
        samples,
        sample_rate,
        level_thread,
    })
}

fn build_stream<T: cpal::SizedSample + Send + 'static>(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    channels: usize,
    samples: Arc<Mutex<Vec<f32>>>,
    levels: SyncSender<f32>,
    convert: impl Fn(T) -> f32 + Send + 'static,
) -> Result<Stream, cpal::BuildStreamError> {
    Ok(device.build_input_stream(
        config,
        move |input: &[T], _| {
            let mut output = samples.lock().expect("audio buffer poisoned");
            let mut sum_squares = 0.0;
            let mut frame_count = 0;
            output.extend(input.chunks_exact(channels).map(|frame| {
                let sample = frame.iter().copied().map(&convert).sum::<f32>() / channels as f32;
                sum_squares += sample * sample;
                frame_count += 1;
                sample
            }));
            if frame_count > 0 {
                let level = (sum_squares / frame_count as f32).sqrt();
                let _ = levels.try_send((level * 10.0).clamp(0.0, 1.0));
            }
        },
        |error| eprintln!("Microphone stream error: {error}"),
        None,
    )?)
}

fn transcribe_and_type(
    recording: Recording,
    model: &Arc<Mutex<Option<Engine>>>,
) -> Result<(), Box<dyn Error>> {
    let Recording {
        stream,
        samples,
        sample_rate,
        level_thread,
    } = recording;
    drop(stream);
    let _ = level_thread.join();
    let samples = samples.lock().expect("audio buffer poisoned");
    if samples.len() < sample_rate as usize / 5 {
        show_status("ready", "Recording too short — try holding Fn longer.");
        println!("Recording was too short; discarded.");
        return Ok(());
    }

    let wav_file = tempfile::Builder::new().suffix(".wav").tempfile()?;
    let wav_path = wav_file.path();
    let spec = hound::WavSpec {
        channels: 1,
        sample_rate,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut writer = hound::WavWriter::create(&wav_path, spec)?;
    for &sample in samples.iter() {
        writer.write_sample((sample.clamp(-1.0, 1.0) * i16::MAX as f32) as i16)?;
    }
    writer.finalize()?;
    drop(samples);

    println!("Transcribing…");
    let mut model_guard = model.lock().expect("ASR model poisoned");
    let model = model_guard
        .as_mut()
        .ok_or("No speech model selected. Choose one from the menu bar.")?;
    let inference_started = Instant::now();
    let text = model.transcribe(wav_path)?;
    let inference_ms = inference_started.elapsed().as_millis();
    drop(model_guard);
    if !text.trim().is_empty() {
        Enigo::new(&Settings::default())?.text(&text)?;
        println!("{text}");
        show_status("complete", &format!("Transcription took {inference_ms} ms"));
    } else {
        show_status("ready", "No speech detected — hold Fn to try again");
    }
    Ok(())
}
