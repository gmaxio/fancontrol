# Roadmap

FanControl is being prepared as a safe, useful Apple Silicon open-source tool.
Items are ordered by user risk and maintainer leverage rather than by novelty.

## Before a stable release

- Collect reproducible compatibility reports for M1, M2, M4, and M5 Macs with
  physical fans, including restore-auto behaviour.
- Add unit coverage for curve interpolation, configuration migration, fan-key
  selection, and hardware-limit validation.
- Replace the setuid helper with a modern, least-privilege macOS helper design.
- Test the signed/notarized DMG workflow in [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md)
  and document release provenance.
- Add a safe diagnostic export that removes usernames, paths, serial numbers,
  and unrelated logs by default.

## Later

- Improve sensor naming across Apple Silicon generations.
- Add import/export for presets with schema validation.
- Localize the application UI while keeping English and Chinese documentation.

The maintainer may disable an unverified control path when evidence suggests a
hardware-specific risk. Open an issue before implementing a new SMC write path.
