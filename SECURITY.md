# Security Policy

## Supported Versions

This repository is currently developed as a personal/experimental desktop shell. Security fixes should target `main` unless release branches are introduced.

## Reporting a Vulnerability

Please do not open a public issue for suspected vulnerabilities. Contact the repository owner privately with:

- A concise description of the issue.
- Reproduction steps or proof of concept, if available.
- Affected platform, Android version, and device model.
- Any relevant logs with tokens, serial numbers, and personal data removed.

## Sensitive Data

RewriteDEX talks to Android devices over ADB and may produce logs containing device serials, package names, notification metadata, or local paths. Scrub logs before sharing them publicly.
