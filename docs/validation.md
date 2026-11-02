# Validation

Implementation verification on 2026-11-01:

- 65 Swift tests passed with no failures using Apple Swift 6.4.
- Packaged Release app launched successfully in isolated demo-export mode outside the execution sandbox and generated all four views. Its sandboxed launch aborts; the unbundled Release binary also passed.
- Universal Apple Silicon/Intel executable verified with minimum macOS 14.0; local bundle uses ad-hoc signing.
- Native AppKit demo exports with wrapping room buttons inspected in Portuguese/dark and English/light, including the separate Settings form.
- Publisher-signature tests cover valid signatures, changed version/hash/size, wrong keys, missing signatures, changed staged files/permissions and symlink rejection.
- Shell and workflow YAML syntax passed; cask generation uses the exact archive hash and rejects version downgrade when updating the main-branch recipe.
- The local release build uses `-debug-info-format none` because Swift Build's dSYM phase hit a filesystem sandbox restriction. The application code remains optimized for release; these local artifacts omit debug symbols.


Automated regression coverage includes:

- HTTP endpoint/token isolation, invalid URLs, authorization failures, no POST replay.
- WebSocket subscription acknowledgement and rejection, removal events.
- Offline command rollback, serial command ordering, merged brightness/color, delayed dimmer cancellation on power-off and session reset.
- Explicit unavailable/unknown physical states, authenticated unlock and confirmation from HA.
- Device creation/removal/recovery, older event rejection, independent scripts, explicit room assignment precedence and unambiguous fallback for virtual climate entities/IR scripts.
- Single device-array publication for a 40-event batch with 1,000 loaded devices.
- Sensor selection and W/kW, Celsius/Fahrenheit conversion, light capability separation, climate increments.
- Isolated credential migration (including failed secure storage), checksum mismatch, archive traversal/symlink/expansion limits and unsigned bundle rejection.

Tests use fictitious credentials and transport mocks. They do not connect to Home Assistant or operate real devices. Keychain tests use an isolated memory backend and temporary metadata files.

Before distributing a release, perform the following with a test Home Assistant instance:

1. Test macOS 14 and a current macOS on Apple Silicon and Intel (or an Intel CI build plus physical smoke test).
2. Confirm Bonjour resolves two servers with different hostnames/ports; verify direct HTTPS and local HTTP.
3. Verify Keychain migration with successful and cancelled access, then interrupt the network during a light command, restart HA, sleep/wake the Mac, revoke the token and switch servers while an adjustment is pending.
4. Check unavailable/jammed locks, opening/closing covers, real biometric/password success/cancellation and HA command permissions. Never use a real access-control device for unattended test automation.
5. Inspect short/long names, 0/10/100 devices, many scenes, light/dark/system themes, both languages, smaller screens and display scaling.
6. Verify tab traversal, slider arrow keys, VoiceOver labels and adjustable actions, color picker access, alert focus/Escape, Reduce Motion and Reduce Transparency.
7. Install an Ed25519-signed GitHub test release; verify tampered/missing signatures/checksums and wrong publisher keys are rejected. For Developer ID builds also test wrong-team bundles. Simulate replacement failure in an isolated installation and recover the retained backup.
8. Profile event bursts with Instruments (Time Profiler, Allocations, Energy Log). The event batch publishes one device-array update, but no fixed frame-rate or battery target is claimed without measurements on representative hardware.

Release publisher signing requires the GitHub Actions secret. Optional Apple notarization and real-device acceptance require external credentials/hardware. Passing unit tests alone does not certify these integrations.
