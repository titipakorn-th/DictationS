use std::{
    error::Error,
    io::Read,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::Duration,
};

pub fn ensure_model(
    repository: &str,
    destination: &Path,
    mut progress: impl FnMut(f64),
    mut cancelled: impl FnMut() -> bool,
) -> Result<(), Box<dyn Error>> {
    std::fs::create_dir_all(destination)?;
    let listing = Command::new("curl")
        .args(["--fail", "--location", "--silent", "--show-error"])
        .arg(format!(
            "https://huggingface.co/api/models/{repository}/tree/main?recursive=true&expand=false"
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
            if !safe_model_file(name) {
                return None;
            }
            Some((name.to_owned(), entry.get("size")?.as_u64()?))
        })
        .collect();
    files.sort_by(|left, right| left.0.cmp(&right.0));
    files.dedup_by(|left, right| left.0 == right.0);
    if !files.iter().any(|(name, _)| name.ends_with(".safetensors"))
        || !["config.json", "vocab.json", "merges.txt"]
            .iter()
            .all(|required| files.iter().any(|(name, _)| name == required))
    {
        return Err(format!(
            "Repository {repository} does not contain a supported Qwen ASR checkpoint"
        )
        .into());
    }

    let total_bytes: u64 = files.iter().map(|(_, size)| size).sum();
    if total_bytes == 0 {
        return Err(format!("Repository {repository} did not report checkpoint file sizes").into());
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
                "https://huggingface.co/{repository}/resolve/main/{name}"
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
            return Err(format!("Could not download {name} from {repository}: {stderr}").into());
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

fn safe_model_file(name: &str) -> bool {
    if name.contains('/')
        || name.contains('\\')
        || name.contains("..")
        || !name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
    {
        return false;
    }
    matches!(
        name,
        "config.json"
            | "vocab.json"
            | "merges.txt"
            | "model.safetensors"
            | "model.safetensors.index.json"
    ) || (name.starts_with("model-") && name.ends_with(".safetensors"))
}

pub fn model_directory(base: &Path, size: &str) -> PathBuf {
    base.join(format!("qwen3-asr-{size}"))
}
