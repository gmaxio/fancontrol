# Contributing to FanControl

Thanks for helping make Mac fan control safer and more broadly compatible.

## Before opening an issue

1. Confirm that no other fan-control utility is running.
2. Restore automatic control (`fancontrol auto`) before collecting evidence.
3. Include your Mac model, chip, macOS version, FanControl version, number of
   fans, and the exact command or UI action. Do not include serial numbers,
   full logs from unrelated applications, passwords, tokens, or personal paths.

Use the hardware compatibility template for successful or failed hardware
reports. Reports from unverified Mac models are valuable even when no code
change is proposed.

## Pull requests

- Keep one behavioural change per pull request and explain the safety impact.
- Add or update documentation for user-visible changes.
- Run the checks in the CI workflow locally where possible.
- Do not add compiled apps, zip archives, private logs, or configuration files
  to Git. Releases belong in GitHub Releases, not in source commits.
- A change affecting `smc.c`, `install.sh`, or privilege boundaries must state
  the allowed keys, expected failure mode, and hardware validation evidence.

## Development principles

The project deliberately prefers a conservative failure over an unbounded SMC
write. Do not expand the helper's write allowlist without a maintainer review,
a documented threat model, and reproducible validation on real hardware.
