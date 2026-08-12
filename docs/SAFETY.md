# Safety and privilege model

FanControl changes fan behaviour on a computer using undocumented SMC
interfaces. Incorrect settings can increase noise, reduce cooling, or leave a
fan in a manual mode until automatic control is restored. Use it only on a Mac
with physical fans, while monitoring temperature and fan behaviour.

## What receives administrator permission

The optional control helper is installed as root-owned setuid executable at:

```text
/Library/PrivilegedHelperTools/io.github.gmaxio.fancontrol.smc
```

Its write interface is intentionally limited to fan target, fan mode, and
legacy fan-unlock keys. It rejects other SMC keys. For a non-zero fan target it
also reads the hardware-reported minimum and maximum RPM and rejects an
out-of-range request. If those limits cannot be read in a supported format, it
refuses the write.

## Operational guidance

- Do not run FanControl alongside another fan-control application.
- Start with automatic mode, then make one small change and observe it.
- `fancontrol auto` returns all fans to macOS automatic control.
- Quitting normally attempts to restore automatic control; a forced kill or a
  power loss cannot guarantee cleanup.
- The default critical-temperature policy is a guardrail, not a substitute for
  Apple hardware protections or monitoring.

## Trust and distribution

Current local builds are ad-hoc signed and are **not notarized**. Do not bypass
macOS security prompts with blanket quarantine-removal commands. Prefer a
source build you can inspect, or wait for a separately signed/notarized release
from this repository.
