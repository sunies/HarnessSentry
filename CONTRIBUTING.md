# Contributing

Thanks for helping improve HarnessSentry. The project is licensed under the Apache License, Version 2.0. Unless explicitly stated otherwise, intentionally submitted contributions are provided under the same license.

## Development setup

Requirements are macOS 14+ and Swift 6.2+. A Community build does not require an Apple Developer account.

```bash
swift build --product HarnessSentry
swift build --product HarnessSentryHook
swift run HarnessSentrySelfTest
```

To verify the application bundle:

```bash
Scripts/build-app.sh release
codesign --verify --deep --strict dist/HarnessSentry.app
plutil -lint dist/HarnessSentry.app/Contents/Info.plist
```

## Design constraints

- Monitoring must not materially slow the monitored Harness or the Mac.
- Prefer notifications and lifecycle Hooks over polling. CLI fallback polling must remain low frequency and emit transitions only.
- Never persist source contents, prompts, model responses, tool output, credentials, request bodies or raw shell commands.
- Every new record type needs a retention path and must respect the database cap.
- Rules must be deterministic, locally explainable and safe to treat as a false positive.
- Do not silently edit a user's Codex, Claude Code or other Harness configuration.
- Endpoint Security code must remain isolated from the Community app and must not claim to be active without the required entitlement and System Extension approval.

## Pull requests

Keep changes focused, add or extend the self-test for storage/normalization/rule changes, and describe privacy and performance impact. UI changes should include a screenshot. Adapter additions should cite the vendor's official executable, bundle identifier or Hook schema rather than guessing.

Do not commit databases, logs, evidence exports, signing certificates, provisioning profiles or user-specific Hook configuration.
