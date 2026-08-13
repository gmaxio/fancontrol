# Hardware compatibility

FanControl focuses on Apple Silicon Macs that expose controllable physical fans
through the SMC interfaces used by this project. It also retains an Intel/T2
compatibility path. A successful build does not prove that every model has the
same keys or command behaviour.

| Hardware | macOS | Status | Evidence |
| --- | --- | --- | --- |
| Mac15,6 (M3 Pro) | 27.0 | Verified by maintainer | Dual-fan read, preset control, and restore-auto reported |
| MacBookPro15,1 (T2) | 15.7 | Verified by maintainer | Read, manual control, and restore-auto reported |
| MacBook Pro 14-inch (2021, Apple M1 Pro) | Tahoe 26.5.2 | Verified by maintainer | Dual-fan read, manual control, preset control, and restore-auto reported; [redacted test-machine screenshot](../assets/screenshots/m1-pro-about-redacted.png) |
| Other M1 Macs | — | Unverified | Community reports requested |
| M2, M4, M5 Macs | — | Unverified | Community reports requested |
| Fanless Macs / desktops without exposed fan keys | — | Unsupported | No compatible physical fan interface |

The M1 Pro result is specific to the 14-inch 2021 MacBook Pro listed above. It
does not establish compatibility for every M1 model. The linked screenshot
documents the test machine only; its serial number has been redacted.

When reporting a model, test in this order: read fan data, perform one bounded
manual target change, restore automatic control, then test a preset. Stop if a
value is implausible or the restore step fails; include the result in a
compatibility issue without publishing unrelated diagnostic data.

The project tracks macOS SMC behaviour from public open-source research,
including [macos-smc-fan](https://github.com/agoodkind/macos-smc-fan), but a
reference implementation is not a substitute for validation on your hardware.
