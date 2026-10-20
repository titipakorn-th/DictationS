use std::{
    error::Error,
    io::Read,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::Duration,
};

/// Which inference engine runs a model.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ModelKind {
    Qwen,
    Parakeet,
}

/// A speech model DictationS can download and run.
pub struct ModelSpec {
    /// Value stored in the user's model preference.
    pub id: &'static str,
    /// Name shown in the menu bar and the status island.
    pub name: &'static str,
    /// Hugging Face repository that hosts the files.
    pub repository: &'static str,
    /// Directory under `models/` that holds the downloaded files.
    pub directory: &'static str,
    /// Files the model needs, by their path in the repository.
    pub files: &'static [&'static str],
    /// Prefix of the weight files to fetch in addition; empty when there are none.
    pub weights_prefix: &'static str,
    pub kind: ModelKind,
}

pub const MODELS: &[ModelSpec] = &[
    ModelSpec {
        id: "0.6b",
        name: "Qwen3-ASR 0.6B",
        repository: "Qwen/Qwen3-ASR-0.6B",
        directory: "qwen3-asr-0.6b",
        files: &["config.json", "vocab.json", "merges.txt"],
        weights_prefix: "model",
        kind: ModelKind::Qwen,
    },
    ModelSpec {
        id: "parakeet-tdt-v3",
        name: "Parakeet TDT v3",
        repository: "istupakov/parakeet-tdt-0.6b-v3-onnx",
        directory: "parakeet-tdt-0.6b-v3",
        files: &[
            "encoder-model.int8.onnx",
            "decoder_joint-model.int8.onnx",
            "vocab.txt",
        ],
        weights_prefix: "",
        kind: ModelKind::Parakeet,
    },
];

/// Look up a model by its preference value.
pub fn model(id: &str) -> Option<&'static ModelSpec> {
    MODELS.iter().find(|spec| spec.id == id)
}

impl ModelSpec {
    /// Whether the model needs this repository file.
    fn wants(&self, name: &str) -> bool {
        self.files.contains(&name)
            || (!self.weights_prefix.is_empty()
                && name.starts_with(self.weights_prefix)
                && (name.ends_with(".safetensors")
                    || name.ends_with(".safetensors.index.json")))
    }
}

/// Whether a downloaded directory holds every file the model needs.
pub fn is_complete(directory: &Path, spec: &ModelSpec) -> bool {
    if !spec.files.iter().all(|name| directory.join(name).is_file()) {
        return false;
    }
    match spec.kind {
        ModelKind::Qwen => qwen_weights_complete(directory),
        ModelKind::Parakeet => true,
    }
}

/// Qwen checkpoints are either a single weight file or an index plus shards.
fn qwen_weights_complete(directory: &Path) -> bool {
    if directory.join("model.safetensors").is_file() {
        return true;
    }
    directory.join("model.safetensors.index.json").is_file()
        && std::fs::read_to_string(directory.join("model.safetensors.index.json")).is_ok_and(
            |index| {
                serde_json::from_str::<serde_json::Value>(&index)
                    .ok()
                    .and_then(|value| value.get("weight_map")?.as_object().cloned())
                    .is_some_and(|weights| {
                        weights
                            .values()
                            .filter_map(|file| file.as_str())
                            .all(|file| directory.join(file).is_file())
                    })
            },
        )
}

pub fn ensure_model(
    spec: &ModelSpec,
    destination: &Path,
    mut progress: impl FnMut(f64),
    mut cancelled: impl FnMut() -> bool,
) -> Result<(), Box<dyn Error>> {
    std::fs::create_dir_all(destination)?;
    let listing = Command::new("curl")
        .args(["--fail", "--location", "--silent", "--show-error"])
        .arg(format!(
            "https://huggingface.co/api/models/{}/tree/main?recursive=true&expand=false",
            spec.repository
        ))
        .output()?;
    if !listing.status.success() {
        return Err(format!(
            "Hugging Face model listing failed: {}",
            String::from_utf8_lossy(&listing.stderr)
        )
        .into());
    }
    let entries: Vec<serde_json::Value> = serde_json::from_slice(&listing.stdout)?;
    let mut files: Vec<(String, u64)> = entries
        .iter()
        .filter_map(|entry| {
            let name = entry.get("path")?.as_str()?;
            if !safe_model_file(name) || !spec.wants(name) {
                return None;
            }
            Some((name.to_owned(), entry.get("size")?.as_u64()?))
        })
        .collect();
    files.sort_by(|left, right| left.0.cmp(&right.0));
    files.dedup_by(|left, right| left.0 == right.0);
    if !spec
        .files
        .iter()
        .all(|required| files.iter().any(|(name, _)| name == required))
        || (!spec.weights_prefix.is_empty()
            && !files.iter().any(|(name, _)| {
                name.starts_with(spec.weights_prefix) && name.ends_with(".safetensors")
            }))
    {
        return Err(format!(
            "Repository {} does not contain a supported {} checkpoint",
            spec.repository, spec.name
        )
        .into());
    }

    let total_bytes: u64 = files.iter().map(|(_, size)| size).sum();
    if total_bytes == 0 {
        return Err(format!(
            "Repository {} did not report checkpoint file sizes",
            spec.repository
        )
        .into());
    }
    let mut completed_bytes = 0u64;
    let mut last_percent = u64::MAX;
    progress(0.0);
    for (name, expected_bytes) in &files {
        if cancelled() {
            return Err("model download cancelled because the selection changed".into());
        }
        let target = destination.join(name);
        if target.is_file() && std::fs::metadata(&target)?.len() > 0 {
            completed_bytes += expected_bytes;
            report_progress(
                &mut progress,
                &mut last_percent,
                completed_bytes,
                total_bytes,
            );
            continue;
        }
        let temporary = destination.join(format!(".{name}.part"));
        let mut child = Command::new("curl")
            .args(["--fail", "--location", "--silent", "--show-error"])
            .arg(format!(
                "https://huggingface.co/{}/resolve/main/{name}",
                spec.repository
            ))
            .arg("--output")
            .arg(&temporary)
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()?;
        let status = loop {
            if cancelled() {
                let _ = child.kill();
                let _ = child.wait();
                let _ = std::fs::remove_file(&temporary);
                return Err("model download cancelled because the selection changed".into());
            }
            if let Some(status) = child.try_wait()? {
                break status;
            }
            let downloaded = std::fs::metadata(&temporary)
                .map(|metadata| metadata.len())
                .unwrap_or(0)
                .min(*expected_bytes);
            report_progress(
                &mut progress,
                &mut last_percent,
                completed_bytes + downloaded,
                total_bytes,
            );
            thread::sleep(Duration::from_millis(200));
        };
        if !status.success() {
            let mut stderr = String::new();
            if let Some(mut output) = child.stderr.take() {
                let _ = output.read_to_string(&mut stderr);
            }
            let _ = std::fs::remove_file(&temporary);
            return Err(format!(
                "Could not download {name} from {}: {stderr}",
                spec.repository
            )
            .into());
        }
        let downloaded_bytes = std::fs::metadata(&temporary)?.len();
        if downloaded_bytes == 0 || downloaded_bytes != *expected_bytes {
            let _ = std::fs::remove_file(&temporary);
            return Err(format!("Downloaded model file {name} has {downloaded_bytes} bytes; expected {expected_bytes}").into());
        }
        std::fs::rename(&temporary, &target)?;
        completed_bytes += downloaded_bytes;
        report_progress(
            &mut progress,
            &mut last_percent,
            completed_bytes,
            total_bytes,
        );
    }
    Ok(())
}

fn report_progress(
    progress: &mut impl FnMut(f64),
    last_percent: &mut u64,
    current: u64,
    total: u64,
) {
    let percent = current
        .saturating_mul(100)
        .checked_div(total)
        .unwrap_or(0)
        .min(100);
    if percent != *last_percent {
        *last_percent = percent;
        progress(percent as f64 / 100.0);
    }
}

/// Repository files are downloaded into the model directory by name, so a
/// path separator or a `..` segment would escape it.
fn safe_model_file(name: &str) -> bool {
    !name.contains('/')
        && !name.contains('\\')
        && !name.contains("..")
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
}

pub fn model_directory(base: &Path, spec: &ModelSpec) -> PathBuf {
    base.join(spec.directory)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parakeet_downloads_only_the_int8_export() {
        let spec = model("parakeet-tdt-v3").expect("parakeet model");
        assert!(spec.wants("encoder-model.int8.onnx"));
        assert!(spec.wants("decoder_joint-model.int8.onnx"));
        assert!(spec.wants("vocab.txt"));
        assert!(!spec.wants("encoder-model.onnx"));
        assert!(!spec.wants("encoder-model.int8.onnx.data"));
        assert!(!spec.wants("nemo128.onnx"));
    }

    #[test]
    fn qwen_downloads_its_weights_but_not_other_files() {
        let spec = model("0.6b").expect("qwen model");
        assert!(spec.wants("model.safetensors"));
        assert!(spec.wants("model-00001-of-00002.safetensors"));
        assert!(spec.wants("config.json"));
        assert!(!spec.wants("tokenizer.json"));
        assert!(!spec.wants("preprocessor_config.json"));
    }

    #[test]
    fn parakeet_directory_is_complete_with_its_three_files() {
        let spec = model("parakeet-tdt-v3").expect("parakeet model");
        let directory = tempfile::tempdir().expect("temp dir");
        for name in spec.files {
            std::fs::write(directory.path().join(name), b"x").expect("write file");
        }
        assert!(is_complete(directory.path(), spec));
        std::fs::remove_file(directory.path().join("vocab.txt")).expect("remove file");
        assert!(!is_complete(directory.path(), spec));
    }
}
