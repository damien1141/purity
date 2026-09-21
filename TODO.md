# todo.md

*note: this is for way later when I actually have freetime lmfao&*

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
```

pros:
- low migration cost
- keeps existing knowledge
- testable module by module
- data moves out of code

cons:
- still bash
- still needs discipline

risk:
- low

estimate:
- one focused afternoon if you avoid gold-plating

---

## option c: declarative post-install layer
status: good after modular bash

shape:
- installer only does:
  - disk
  - luks
  - btrfs
  - base system
  - bootloader
  - user
- separate layer applies:
  - packages
  - services
  - dotfiles
  - dns
  - audio
  - wm config

possible tools:
1. `chezmoi` for dotfiles
2. custom idempotent bash modules
3. ansible local playbook
4. nix if you want full declarative pain

pros:
- config becomes repeatable
- reinstall becomes less special
- dotfiles and system state stop drifting

cons:
- more abstraction
- needs clear boundary between bootstrap and state

risk:
- medium

estimate:
- one day for a sane first version

---

## option d: rust/go orchestrator
status: later, only if bash pain persists

shape:
- typed phase runner
- explicit state file
- command runner with logs
- structured errors
- vm test harness integration

pros:
- better state handling
- easier to test
- better long-term maintainability

cons:
- high build cost
- easy to over-engineer
- not needed yet

risk:
- high if done too early

estimate:
- multiple days minimum

---

## option e: image / golden install
status: overkill for one machine, useful for fleet

shape:
- prebuilt rootfs/squashfs/tarball
- small applicator script
- disk layer applies image
- config layer customizes

pros:
- fastest reinstall
- highly reproducible

cons:
- image maintenance cost
- kernel/driver/version drift
- harder to debug

risk:
- high complexity

estimate:
- several days to weeks depending scope

---

# recommended path

do not jump to rust or image builds yet.

path:

1. freeze current script
2. harden current script
3. modularize bash
4. add vm test loop
5. split bootstrap from declarative state
6. consider rust rewrite only after step 5 hurts

---

# phase 0: freeze baseline

estimate: 15-30 minutes

- [ ] create git repo if missing
- [ ] commit current installer as known-good v0
- [ ] tag it: `v0-monolith`
- [ ] copy current script to `install-v0.sh` for reference
- [ ] write one paragraph in `notes.md`: what currently works and what is known flaky

commands:

```bash
git init
git add .
git commit -m "freeze v0 installer"
git tag v0-monolith
cp install.sh install-v0.sh
```

done when:
- current state is recoverable
- future changes can be diffed against v0

---

# phase 1: harden the monolith

estimate: 1-2 hours

goal: make the current script safer and more testable without restructuring it.

## config extraction

- [ ] move user-facing defaults into `installer.env`
- [ ] allow environment overrides for:
  - `DISK`
  - `USERNAME`
  - `HOSTNAME`
  - `TIMEZONE`
  - `SWAP_SIZE_GIB`
  - `DNSMASQ_WHITELIST`
  - `INSTALL_SSH`

example `installer.env`:

```bash
DISK=""
USERNAME="damien"
HOSTNAME="artix"
TIMEZONE="America/Chicago"
SWAP_SIZE_GIB=""
DNSMASQ_WHITELIST=1
INSTALL_SSH=1
```

done when:
- `ask_user` only prompts for values not already provided

---

## package list extraction

- [ ] move official package list to `config/packages/official.txt`
- [ ] move aur target list to `config/packages/aur.txt`
- [ ] move aur fallback chains to `config/packages/fallbacks.txt`

possible fallback syntax:

```text
betterbird-bin betterbird-git betterbird betterbird-beta-bin
opentubex-bin opentubex-git
onlyoffice-bin onlyoffice-git onlyoffice
```

done when:
- changing package list does not require editing bash logic

---

## logging improvements

- [ ] keep final failure report in `/root/artix-install.failures`
- [ ] copy log to target root after successful install
- [ ] add phase markers to log:
  - `phase: disk`
  - `phase: base`
  - `phase: repos`
  - `phase: packages`
  - `phase: services`
  - `phase: aur`
  - `phase: verify`

done when:
- you can tell where a failure happened from the log alone

---

# phase 2: modular bash

estimate: 3-6 hours

goal: split the monolith into testable modules while keeping behavior identical.

## target layout

```text
install.sh
lib/
  log.sh
  state.sh
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
  services/
  templates/
```

## tasks

- [ ] create `lib/log.sh`
  - `info`
  - `warn`
  - `die`
  - failure array helpers

- [ ] create `lib/state.sh`
  - global variables
  - phase markers
  - state file writer

- [ ] create `lib/disk.sh`
  - disk selection
  - partitioning
  - ssd/uefi detection

- [ ] create `lib/luks.sh`
  - luks format
  - luks open
  - uuid capture
  - cleanup helpers

- [ ] create `lib/btrfs.sh`
  - subvolumes
  - mount order
  - swapfile

- [ ] create `lib/repos.sh`
  - artix repo handling
  - cachyos repo handling
  - pacman.conf mutation

- [ ] create `lib/packages.sh`
  - official package install
  - package list loading
  - fallback install helpers

- [ ] create `lib/aur.sh`
  - aura build
  - aur batch install
  - fallback chains
  - pkgsum retry

- [ ] create `lib/services.sh`
  - runit enablement
  - service candidate lists

- [ ] create `lib/verify.sh`
  - post-install checks

done when:
- `install.sh` is mostly orchestration
- no major function exceeds ~100 lines
- modules can be sourced without running destructive actions

---

# phase 3: make it vm-testable

estimate: 2-4 hours

goal: run the installer unattended in qemu/libvirt.

## preseed support

- [ ] add `AUTO=1` mode
- [ ] fail safely if required variables are missing
- [ ] accept answers from `installer.env`
- [ ] add `FORCE_DISK=1` confirmation bypass for vm testing only

example:

```bash
AUTO=1 \
DISK=/dev/vda \
USERNAME=damien \
HOSTNAME=artix-vm \
TIMEZONE=America/Chicago \
SWAP_SIZE_GIB=4 \
DNSMASQ_WHITELIST=0 \
INSTALL_SSH=1 \
FORCE_DISK=1 \
./install.sh
```

done when:
- installer can run in a vm without keyboard input

---

## vm harness

- [ ] create `test/vm.sh`
- [ ] create disposable disk image: 20g minimum
- [ ] boot artix live iso
- [ ] copy installer into vm
- [ ] run installer with preseed env
- [ ] capture serial console log

done when:
- one command starts a disposable install test

---

## smoke test

- [ ] vm boots to luks prompt
- [ ] luks password unlocks root
- [ ] limine boots kernel
- [ ] user login works
- [ ] network works
- [ ] dns resolves
- [ ] xorg/awesome starts if gpu/vm video allows

done when:
- you can prove a full install without touching real hardware

---

# phase 4: split bootstrap from system state

estimate: half day to one day

goal: installer stops being responsible for every long-lived config detail.

## boundary

bootstrap owns:
- disk
- luks
- btrfs
- fstab
- base packages
- bootloader
- user creation
- initial service enablement

state layer owns:
- dotfiles
- wm config
- dns config
- audio config
- app package lists
- user services
- cleanup timers

## tasks

- [ ] define boundary in `docs/architecture.md`
- [ ] move dotfile copying to a separate script/module
- [ ] move dns config to a separate script/module
- [ ] move audio/pipewire config to a separate script/module
- [ ] move aur app list to data files
- [ ] create `apply-state.sh`

done when:
- disk install can finish without knowing every app preference
- state can be reapplied after install

---

# phase 5: declarative state layer

estimate: one day minimum

choose one:

## lightweight option: idempotent bash modules

shape:

```text
state/
  dns.sh
  audio.sh
  wm.sh
  services.sh
  dotfiles.sh
```

rules:
- every module must be safe to run twice
- every module must print what changed
- every module must exit non-zero on real failure

use if:
- you want low abstraction
- you want to stay in your current stack

---

## dotfiles option: chezmoi

use for:
- home directory config
- fish
- awesome
- xresources
- mpd
- kitty

do not use for:
- disk layout
- bootloader
- luks

---

## ansible local option

use if:
- you want package/service/file state in one place
- you want dry-run and diff

warning:
- ansible can become its own infrastructure project
- do not choose it unless you want to maintain playbooks

---

# component decisions

## pacman/repos

open questions:
- [ ] decide: stock pacman + generic cachyos repo, or cachyos-pacman + v3/v4 repos
- [ ] replace `awk` pacman.conf mutation with a maintained template if possible
- [ ] add repo verification step after `pacman -Sy`

recommended default:
1. use stock pacman first.
2. use generic cachyos packages unless v3/v4 gives measurable benefit.
3. only move to cachyos-pacman if stock pacman repo handling becomes a blocker.

---

## aur

open questions:
- [ ] keep aura as primary helper?
- [ ] store fallback chains in data file?
- [ ] keep build dir at `/tmp/aura-build` or move to persistent cache?

recommended default:
- keep aura for now.
- move fallback chains to `config/packages/fallbacks.txt`.
- keep build dir temporary until install succeeds.
- add per-package logs under `/root/aur-logs/`.

---

## services

open questions:
- [ ] canonical service list file
- [ ] service candidate aliases file
- [ ] verify service state after install

example:

```text
dbus dbus-1
elogind
NetworkManager networkmanager
iwd
cronie crond cron
dnsmasq
dnscrypt-proxy
acpid
chronyd
```

done when:
- enabling services is data-driven, not hardcoded in many places

---

## dns

open questions:
- [ ] keep dnsmasq + dnscrypt-proxy?
- [ ] keep whitelist mode?
- [ ] avoid immutable resolv.conf?

recommended default:
- keep dnsmasq + dnscrypt-proxy.
- keep networkmanager `dns=none`.
- do not use `chattr +i` unless you want the operational pain.

---

## bootloader

open questions:
- [ ] keep limine as only bootloader?
- [ ] test bios hook when `/boot` is unmounted
- [ ] add fallback boot entry verification

recommended default:
- keep limine.
- add a verify step that checks kernel/initramfs/limine.conf exist after install.

---

# risk register

1. pacman.conf mutation
   risk: high
   symptom: repos not injected or pacman broken
   fix: template file or dedicated repo include strategy

2. aur package names
   risk: medium
   symptom: package renamed/blacklisted
   fix: fallback chains in data file + manual override

3. cachyos repo compatibility
   risk: medium-high
   symptom: architecture/package rejection
   fix: choose stock generic repo or cachyos-pacman explicitly

4. runit service names
   risk: medium
   symptom: service not enabled due to naming drift
   fix: candidate alias file

5. vm vs real hardware divergence
   risk: medium
   symptom: vm passes, real machine fails
   fix: keep one hardware smoke checklist

6. over-engineering
   risk: high
   symptom: rewriting before test loop exists
   fix: phase gates above

---

# test matrix

start small. do not build the full matrix yet.

## minimum matrix
- [ ] uefi vm install
- [ ] bios vm install

## later matrix
- [ ] real uefi ssd
- [ ] real bios machine if relevant
- [ ] nvidia
- [ ] amd
- [ ] intel

stop rule:
- do not expand matrix until minimum vm matrix passes twice

---

# acceptance criteria

## v1 modular installer is done when:
- [ ] `install.sh` sources modules
- [ ] package lists are external
- [ ] aur fallbacks are external
- [ ] one vm install completes unattended
- [ ] failure report is generated
- [ ] no destructive action runs without explicit confirmation unless `FORCE_DISK=1`

## v2 state layer is done when:
- [ ] disk bootstrap and state application are separate
- [ ] dotfiles can be reapplied
- [ ] dns/audio/services config can be reapplied
- [ ] reinstall requires less than 10 manual decisions

---

# decision log

use this format when making a permanent choice.

```text
date:
decision:
context:
options considered:
chosen:
reason:
cost:
revisit when:
```

first entries to create:

- [ ] decision: modular bash before rust rewrite
- [ ] decision: stock pacman vs cachyos-pacman
- [ ] decision: aur helper remains aura
- [ ] decision: dns stack remains dnsmasq + dnscrypt-proxy
- [ ] decision: state layer tool

---

# possible later improvements

do not do these yet unless a real pain appears.

- [ ] package cache preservation across installs
- [ ] aur source cache preservation
- [ ] automatic rollback snapshot before system update
- [ ] limine entry generation from installed kernel metadata
- [ ] hardware profile detection files
- [ ] offline install mode
- [ ] signed config/profile bundles
- [ ] rust orchestrator
- [ ] image-based reinstall

---

# stop conditions

stop and reassess if:

1. modularization takes more than one afternoon without a working install
2. vm harness becomes harder than the installer itself
3. declarative layer requires more abstraction than the problem deserves
4. you are optimizing infrastructure instead of shipping the primary goal
```

next action: commit `v0`, then do phase 0 only.
