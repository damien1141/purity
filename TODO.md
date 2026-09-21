# todo.md

*note: this is for way later when I actually have freetime lmfao&*

## next action
1. save this file.
2. commit the current installer as `v0` before changing anything.
3. do phase 0 only.

---

# north star

turn the installer into:

1. a destructive disk bootstrap
2. a testable phase runner
3. a declarative system-state layer
4. a small set of data files for packages, services, and fallbacks

goal:
- reinstall can be tested in a vm
- failure points are visible
- config changes do not require reading 1200 lines of bash
- no manual repetition survives more than one incident

---

# current state

## what is strong
- luks + btrfs + limine flow is solid
- cleanup trap is good
- aur fallback/retry design is good
- environment hygiene is good: root checks, logging, failure array, swap handling

## what is weak
- monolith: one file, many global variables
- interactive prompts block vm testing
- inline `awk` mutation of `pacman.conf` is brittle
- package lists and aur fallback chains are embedded in code
- no clean resume/checkpoint model
- no automated vm smoke test

---

# anti-gold-plating rules

1. do not rewrite in rust until modular bash works and hurts.
2. do not build a perfect declarative system before the installer is testable.
3. do not automate hardware matrix testing before one vm profile passes.
4. default to the deployable 80%.
5. if the same fix fails twice, stop patching and inspect the shared assumption.
6. every loop gets a stopping rule before it starts.

---

# architecture options

## option a: keep monolith
status: not recommended long-term

use if:
- you reinstall rarely
- only you maintain it
- you accept random maintenance pain

pros:
- zero migration cost
- already works

cons:
- hard to test
- hard to resume
- hard to reason about
- global state grows

risk:
- medium-high over time

---

## option b: modular bash
status: recommended next step

shape:

```text
install.sh
lib/
  log.sh
  disk.sh
  luks.sh
  btrfs.sh
  repos.sh
  packages.sh
  aur.sh
  services.sh
  verify.sh
config/
  installer.env
  packages/
    official.txt
    aur.txt
    fallbacks.txt
  services/
    runit.txt
  templates/
    pacman.conf
