# Installer TODO

## Critical

- [x] Add disk space check before partitioning — verify target disk has sufficient free space (min 10GiB)
- [x] Add kernel update pacman hook for limine — `/etc/pacman.d/hooks/limine.hook` + `/usr/local/bin/limine-kernel-update.sh` to reinstall limine boot files on kernel updates
- [x] Post-install system update via `aura -Syyu`

## Important

- [x] AUR build artifact cleanup — `cleanup_aur_builds()` offers to remove `~/src` after build
- [x] Add ufw firewall — install ufw, default deny incoming, allow outgoing, allow SSH if enabled
- [x] Add paccache cleanup to biweekly + clean up after install — `cleanup_pacman_cache()` runs post-install, biweekly cron already has paccache

## Nice-to-have

- [x] Add SSH option — `INSTALL_SSH` variable, prompt in ask_user, `install_ssh()` function
- [x] Check for existing/open LUKS — `check_existing_luks()` closes cryptroot, warns about existing LUKS header
- [x] Swapfile cleanup on re-install — added to `setup_swapfile()`, removes existing swapfile before creating new one
- [x] Timesync verification — `verify_timesync()` checks openntpd sync status after setup

## Directory/Font Wiring (completed)

- [x] Updated directory structure references (emoji, limine-assets, network moved under extra/)
- [x] Material Design Icons font installation (5 variants: Regular, Outlined, Round, Sharp, Two Tone)
- [x] Fontconfig cleanup (removed no-op match)
- [x] README updated with new project structure and font listing