# Upstream

This crate is keytap 0.4.0 from [jamiepine/keytap](https://github.com/jamiepine/keytap), copied from its crates.io source. The upstream manifest declares `MIT OR Apache-2.0`.

Local changes: the macOS `FlagsChanged` decoder tracks `kCGEventFlagMaskSecondaryFn`, allowing Fn/Globe key down and up events to reach callers. The macOS tap is session-level and returns events unchanged through a default tap, so Accessibility authorization can replace the upstream Input Monitoring preflight/listen-only path.
