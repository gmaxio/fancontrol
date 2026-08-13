# Signed and notarized distribution

The public preview is source-first. Its local build uses an ad-hoc signature,
which is useful for development but does not identify the publisher to
Gatekeeper. A future downloadable release should use a Developer ID
Application certificate, Hardened Runtime, Apple notarization, and a stapled
ticket.

## What Apple notarization means

Notarization is an automated Apple service for software distributed outside the
Mac App Store. Apple checks the submitted, Developer ID-signed software for
malicious content and signing problems, then issues a ticket that Gatekeeper
can verify. It is not App Store review.

Apple's current requirements for a custom workflow include:

- a valid **Developer ID Application** signature for every executable;
- the **Hardened Runtime** enabled;
- a secure signing timestamp; and
- no `com.apple.security.get-task-allow` entitlement set to true.

See Apple's [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates),
[notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution),
[custom `notarytool` workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow),
and [Hardened Runtime documentation](https://developer.apple.com/documentation/xcode/configuring-the-hardened-runtime).

## One-time setup

1. Join the Apple Developer Program as an individual or organization. Apple
   currently lists the program at USD 99 per membership year, with regional
   pricing shown during enrollment.
2. As the Account Holder, create a **Developer ID Application** certificate in
   Certificates, Identifiers & Profiles and install it in this Mac's keychain.
3. Confirm that the identity is visible:

   ```bash
   security find-identity -v -p codesigning
   ```

4. Create an app-specific password for the Apple ID used for notarization. Do
   not put it in Git, a shell history file, CI logs, or a repository secret in
   plain text.
5. Store it in the login keychain under a `notarytool` profile:

   ```bash
   xcrun notarytool store-credentials fancontrol-notary \
     --apple-id "you@example.com" \
     --team-id "TEAMID1234" \
     --password "app-specific-password"
   ```

The public repository never needs the password. `notarize_release.sh` reads
the keychain profile by name.

## Build and notarize

After the certificate and profile exist:

```bash
cd fancontrol
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID1234)" \
NOTARYTOOL_PROFILE=fancontrol-notary \
zsh notarize_release.sh
```

The script builds both architectures, signs the SMC executable and app with
Hardened Runtime, creates a DMG, submits the DMG with `notarytool --wait`,
staples the returned ticket, and validates it with `stapler` and `spctl`.

The script deliberately does not upload a GitHub Release. Test the stapled DMG
on a clean Mac first, then attach it to a versioned Release. Keep the source
archive and DMG checksums in the Release notes.

## Why the current custom installer is not the first notarized artifact

`fancontrol-dist.zip` contains a shell installer that copies a helper into
`/Library/PrivilegedHelperTools` and marks it setuid. This is a sensitive custom
installation path. Apple documents that custom third-party installers may
require notarizing both the payload and the outer installer. The project is
therefore prioritizing a least-privilege helper redesign before presenting the
full CLI bundle as a polished, notarized installer.

The first signed distribution target is the app DMG. It still contains the
same helper binary in the app resources, so the helper is included in Apple's
notarization scan; the installation boundary remains documented in
[SAFETY.md](SAFETY.md).

## Verification checklist

- `codesign --verify --deep --strict FanControl.app` succeeds.
- `codesign -dvvv FanControl.app` shows a Developer ID Authority, Team ID, and
  Hardened Runtime rather than `Signature=adhoc`.
- `xcrun stapler validate FanControl.dmg` succeeds.
- `spctl --assess --type open --context context:primary-signature --verbose=4
  FanControl.dmg` accepts the DMG.
- A clean Mac can open the DMG without blanket quarantine removal.
- The app can read fans before helper installation and restores automatic mode
  after a normal exit.

