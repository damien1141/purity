# Progress: Verify install.sh Packages

## Goal
Verify every package referenced by install.sh on CachyOS using `aura -As` for AUR packages and `aura -Ss` for repository packages; exclude runit packages as requested.

## Steps
- [x] Create verification plan
- [x] Read install.sh and extract package names
- [x] Classify repository, AUR, and excluded runit entries
- [ ] Run `aura -Ss` for repository packages and `aura -As` for AUR packages
- [ ] Review outputs and produce a package-by-package result

## Evidence
- Workspace: `/home/solis/Documentos/Code/purity`
- Target: `install.sh`
- Host note: CachyOS; runit package verification intentionally excluded.

## Errors
None yet.

## Current task: CachyOS repositories for Artix/runit
- [x] Inspect the existing `configure_repos()` implementation and Artix repository ordering guidance
- [ ] Replace the custom `[cachyos]` system-package repository with CPU-selected optimized repositories
- [ ] Verify shell syntax, generated pacman configuration, repository ordering, and mirror endpoints

### Decision
Keep Artix's `system`/`world`/`galaxy`/`lib32` repositories ahead of CachyOS so runit-compatible Artix packages win. Omit `[cachyos]`, `[cachyos-core]`, and `[cachyos-extra]` because they provide CachyOS system packages.
