# Changelog

All notable changes to this project are documented here.

## [Unreleased]

### Added
- Packaging: `LICENSE` (MIT), `CHANGELOG.md`, a real `package/0` with a `GitHub` link and an
  explicit `files` list, `docs/0`, and `ex_doc` as a dev dependency.
- Version control. The library previously had no git history at all, which is why no app could
  depend on it: `{:asas, github: "nagieeb0/asas"}` had nothing to resolve.

### Changed
- Install instructions now use `github:` rather than `path: "../asas"`. A path dependency only
  resolves on one laptop and blocks every remote build.

## [0.1.0] - 2026-09-04

### Added
- `Asas.Phone` — EG + SA mobile normalisation to E.164. Strict about shape, never about the
  operator prefix.
- `Asas.Digits` — Arabic-Indic and Persian numeral folding, both directions.
- `Asas.Akedly` — Akedly V1.2 phone-OTP client with a named error taxonomy and no retries.
- `Asas.RateLimit` — ETS fixed-window limiter with a lock-free counter and a periodic sweep.
- `Asas.Storage` — blob storage behaviour with local and S3-compatible adapters, content-type
  whitelisting and magic-byte sniffing.
- `Asas.Release` — `use`-able migrate/rollback/seed tasks with an advisory-locked, once-only seed.
- `Asas.Locale` — locale resolution as a Plug and a LiveView `on_mount`.
