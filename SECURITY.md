# Security policy

FanControl can install a narrow, administrator-authorized helper at
`/Library/PrivilegedHelperTools/io.github.gmaxio.fancontrol.smc`. Treat defects that
could broaden that helper's permissions, write non-fan SMC keys, bypass the
RPM guardrails, or prevent a return to automatic control as security issues.

## Reporting a vulnerability

Please do **not** publish proof-of-concept code or exploitation details in a
public issue. Use GitHub's **Security** tab and select **Report a vulnerability**
to send a private report. If private reporting is not enabled for a release,
open a minimal issue asking for a private contact channel; do not include the
details there.

Include the FanControl version, macOS version, Mac model, whether the helper
was installed, reproducible steps, and the expected versus actual behaviour.
We will acknowledge a report within seven calendar days and will coordinate a
fix and disclosure timeline with the reporter when possible.

## Supported versions

Only the latest published release receives security fixes. Development builds
and forks may be used for diagnosis but are not supported releases.

## Safety boundary

FanControl is not an Apple product and uses undocumented SMC interfaces. A
security fix may disable a feature on unverified hardware rather than risk a
broader privileged write capability.
