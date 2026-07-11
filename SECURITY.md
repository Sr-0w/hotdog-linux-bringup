# Security policy

This project manipulates boot images and privileged device interfaces. Treat
all scripts as development tooling, not as a hardened flashing product.

## Reporting a security issue

Use GitHub's private security-advisory feature for vulnerabilities involving:

- arbitrary command execution
- unsafe partition targeting
- credential exposure
- malicious artifact substitution
- rescue or rollback bypasses

Do not include private partition dumps, proprietary firmware, credentials, or
unique device identifiers in a public issue.

## Supported versions

Only the current default branch is maintained. Superseded boot candidates and
local experiment records are not supported release artifacts.
