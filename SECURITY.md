# Security Policy

## Supported versions

HarnessSentry is currently an early development project without a stable supported release line. Security fixes are applied to the latest revision only.

## Reporting a vulnerability

Please use the repository's **Security → Report a vulnerability** flow (GitHub Private Vulnerability Reporting) when it is enabled. Include the affected revision, macOS version, reproduction steps and impact. Do not attach a real HarnessSentry database, source code, credentials, prompts or unredacted evidence exports.

If private reporting is not enabled, open a minimal public issue asking the maintainer for a private contact channel. Do not publish exploit details or sensitive sample data in that issue.

## Particularly relevant reports

- collection or persistence of content that the privacy policy says is discarded;
- command injection or unsafe Hook configuration generation;
- privilege boundary errors in future Endpoint Security components;
- evidence export leaking fields not visible in the UI;
- unbounded CPU, memory or disk usage triggered by untrusted Hook input;
- tampering that can falsely mark monitoring as healthy.

False positives in anomaly rules are normally correctness issues rather than security vulnerabilities, unless they allow an attacker to reliably conceal activity.
