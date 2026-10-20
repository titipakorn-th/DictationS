//! Transcribe a WAV file with a downloaded model.
//!
//! ```sh
//! cargo run --release --example transcribe -- parakeet-tdt-v3 recording.wav
//! ```

use std::{error::Error, path::PathBuf, time::Instant};

use dictations::{
    engine,
    model_store::{self},
};

fn main() -> Result<(), Box<dyn Error>> {
    let mut args = std::env::args().skip(1);
    let id = args
        .next()
        .ok_or("usage: transcribe <model-id> <wav-file>")?;
    let wav = args.next().ok_or("usage: transcribe <model-id> <wav-file>")?;
    let spec = model_store::model(&id).ok_or_else(|| format!("unknown model {id}"))?;
    let home = std::env::var_os("HOME").ok_or("HOME is not set")?;
    let models = PathBuf::from(home).join("Library/Application Support/DictationS/models");
    let directory = model_store::model_directory(&models, spec);
    let mut engine = engine::load(spec, &directory)?;
    let started = Instant::now();
    let text = engine.transcribe(std::path::Path::new(&wav))?;
    println!("{text}");
    eprintln!("{} took {:?}", spec.name, started.elapsed());
    Ok(())
}
