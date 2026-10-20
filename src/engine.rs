//! Loading and running the speech models DictationS supports.

use std::{error::Error, path::Path};

use parakeet_rs::{ExecutionConfig, ExecutionProvider, ParakeetTDT, TimestampMode, Transcriber};
use qwen_asr::{context::QwenCtx, transcribe};

use crate::model_store::{ModelKind, ModelSpec};

/// A loaded speech model.
pub enum Engine {
    Qwen(QwenCtx),
    Parakeet(ParakeetTDT),
}

/// Load a model from the directory that holds its files.
pub fn load(spec: &ModelSpec, directory: &Path) -> Result<Engine, Box<dyn Error>> {
    match spec.kind {
        ModelKind::Qwen => Ok(Engine::Qwen(
            QwenCtx::load(directory.to_string_lossy().as_ref())
                .ok_or_else(|| format!("Could not load CPU model from {}", directory.display()))?,
        )),
        ModelKind::Parakeet => {
            // ONNX Runtime on the CPU. The CoreML provider is slower for these
            // graphs because their input shapes are dynamic.
            let environment = parakeet_rs::ort::init().build()?;
            let config = ExecutionConfig::new()
                .with_execution_provider(ExecutionProvider::Cpu)
                .with_environment(environment);
            Ok(Engine::Parakeet(ParakeetTDT::from_pretrained(
                directory,
                Some(config),
            )?))
        }
    }
}

impl Engine {
    /// Transcribe a WAV file and return the text.
    pub fn transcribe(&mut self, wav_path: &Path) -> Result<String, Box<dyn Error>> {
        match self {
            Engine::Qwen(model) => {
                model.want_language_detection = true;
                transcribe::transcribe(model, &wav_path.to_string_lossy())
                    .ok_or_else(|| "Qwen3-ASR could not decode this recording".into())
            }
            Engine::Parakeet(model) => {
                // Parakeet wants 16 kHz mono samples; the Qwen crate already
                // downmixes and resamples a 16-bit PCM WAV to that.
                let samples = qwen_asr::audio::load_wav(&wav_path.to_string_lossy())
                    .ok_or("Could not read the recording as 16 kHz mono audio")?;
                let result =
                    model.transcribe_samples(samples, 16_000, 1, Some(TimestampMode::Sentences))?;
                Ok(result.text)
            }
        }
    }
}
