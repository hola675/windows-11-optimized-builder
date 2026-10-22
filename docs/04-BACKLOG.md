# Roadmap

## Phase 0 — Audit and scaffold
- [x] Initialize repository and development branch.
- [x] Document scope and protected components.
- [x] Add non-destructive preflight.
- [ ] Inspect source archive provenance and licensing before importing files.
- [ ] Audit removals, service changes, registry tweaks and answer-file settings.

## Phase 1 — Safe baseline
- [ ] Integrate audited builder and retain attribution/license.
- [ ] Add exact package manifest by Windows build/edition.
- [ ] Add dry-run/report mode and structured logs.
- [ ] Ensure cleanup only touches owned scratch directories.
- [ ] Add failure-handling and rollback tests.

## Phase 2 — Validation
- [ ] Windows-hosted PowerShell tests.
- [ ] Build official media in a disposable VM.
- [ ] Test OOBE, activation, updates, Store, winget, Defender and developer toolchains.
- [ ] Test repair, recovery, feature updates and in-place servicing.

## Phase 3 — Profiles and release
- [ ] Balanced Developer profile.
- [ ] Office profile only if distinct policy is justified by test results.
- [ ] Generate manifest and checksums.
- [ ] Publish release notes and evidence; never upload Windows ISO payloads.
