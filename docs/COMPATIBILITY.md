# Hardware compatibility

FanControl focuses on Apple Silicon Macs that expose controllable physical fans
through the SMC interfaces used by this project. It also retains an Intel/T2
compatibility path. A successful build does not prove that every model has the
same keys or command behaviour.

| Hardware | macOS | Status | Evidence |
| --- | --- | --- | --- |
| Mac15,6 (M3 Pro) | 27.0 | Verified by maintainer | Dual-fan read, preset control, and restore-auto reported |
| MacBookPro15,1 (T2) | 15.7 | Verified by maintainer | Read, manual control, and restore-auto reported |
| M1, M2, M4, M5 Macs | — | Unverified | Community reports requested |
| Fanless Macs / desktops without exposed fan keys | — | Unsupported | No compatible physical fan interface |

When reporting a model, test in this order: read fan data, perform one bounded
manual target change, restore automatic control, then test a preset. Stop if a
value is implausible or the restore step fails; include the result in a
compatibility issue without publishing unrelated diagnostic data.

The project tracks macOS SMC behaviour from public open-source research,
including [macos-smc-fan](https://github.com/agoodkind/macos-smc-fan), but a
reference implementation is not a substitute for validation on your hardware.
