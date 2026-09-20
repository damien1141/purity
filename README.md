# purity

HEAVILY Opinionated Artix Linux runit installer. Targets **Artix + runit + CachyOS bore-lto kernel + Limine + LUKS2 + btrfs**.

Destructive — run from an Artix live environment as root.

Right sided vertical bar, running xorg that feels like wayland bc I made a custom layout with a physics engine, scientific as fuck auto nightlight. why you may ask? BECAUSE WE DONT FUCK WITH CUSTERS

*note: the UI is in mandarin becuase im currently learning chinese- install kilo code and get a free agent to change it all to english*

[insert sick ass workflow video here later im probably not gonna do this, at the very least ill put some screenshots, also probably not gonna do that]

## Quick Start

```bash
sudo ./install.sh
```

The script is fully interactive. Prompts for:
- **Username** (default: `damien`)
- **Hostname** (default: `artix`)
- **Swap size** in GiB (default: matches RAM)
- **User + LUKS password** (typed twice, hidden)
- **Timezone** (default: `America/Chicago`)
- **dnsmasq whitelist** — enable/disable domain blocking (default: enabled)

Before partitioning, it displays the target disk and requires typing `YES` to confirm.

## What It Installs

| Component | Details |
|-----------|---------|
| **Kernel** | `linux-cachyos-bore-lto` (fallback: `linux-cachyos-bore`, `linux-cachyos`, `linux`) |
| **Bootloader** | Limine (UEFI + BIOS) |
| **Encryption** | LUKS2 (aes-xts-plain64, 512-bit key, argon2id PBKDF2, SHA-512) |
| **Filesystem** | Btrfs (zstd:1, noatime, space_cache=v2) with subvolumes: `@`, `@home`, `@var`, `@cache`, `@log`, `@tmp`, `@swap`, `@snapshots` |
| **Init** | runit |
| **Display** | Awesome WM, Pipewire, Xorg |
| **DNS** | dnsmasq + dnscrypt-proxy (whitelist-based, geo-fenced to EU) |
| **NTP** | openntpd (pool.ntp.org, slew correction) |
| **Desktop apps** | Thunar, Kitty, OBS, btop, GIMP, Bluez, mpd, ncmpcpp, starship, eza |
| **AUR (via aura)** | Gram, Obsidian, LibreWolf, OpenTubeX, Anki, Bun, OnlyOffice, betterlockscreen, mpdris2, themes, fonts |
| **Local build** | `jaiba` (TUI KeePass manager) from `extra/jaiba` → `/usr/local/bin/jaiba` (yall get early access to my keepass manager that i stole from some guy on the internet and added a shit ton of features to) |

## Project Structure

```
purity/
├── install.sh              # Main installer
├── extra/
│   ├── fonts/
│   │   ├── emoji/NotoColorEmoji.ttf
│   │   └── material-design-icons/
│   │       ├── MaterialIcons-Regular.ttf
│   │       ├── MaterialIconsOutlined-Regular.otf
│   │       ├── MaterialIconsRound-Regular.otf
│   │       ├── MaterialIconsSharp-Regular.otf
│   │       └── MaterialIconsTwoTone-Regular.otf
│   ├── limine-assets/black.bmp
│   ├── network/
│   │   ├── dnsmasq.conf
│   │   └── dnscrypt-proxy.toml
│   └── jaiba/              # Local Rust project (jaiba)
├── home/                   # Dotfiles (copied to ~$USER/)
```

## DNS Pipeline

```
Application → 127.0.0.1:53 (dnsmasq) → 127.0.0.1:5354 (dnscrypt-proxy) → upstream
```

- **Whitelist enabled** (default): dnsmasq allows ~224 domains; everything else returns `0.0.0.0`
- **Whitelist disabled**: all queries forwarded to dnscrypt-proxy (no blocking)
- dnscrypt-proxy: anonymized relays, DNSSEC required, EU servers only (FR/DE/CH/NL/DK) (your isp is gonna have a hard time seeing what you goon to lmfao)
- `/etc/resolv.conf` locked immutable to `127.0.0.1`/`::1` post-install

## Hardware Detection

- **GPU**: Auto-detects NVIDIA/AMD/Intel → installs matching drivers (nvidia-dkms, mesa, vulkan)
- **CPU microcode**: AMD → `amd-ucode`, else `intel-ucode`
- **SSD/NVMe**: Enables btrfs `ssd` mount option
- **UEFI/BIOS**: Detects firmware type, configures Limine accordingly

## Maintenance (cronie)

| Schedule | Job | Description |
|----------|-----|-------------|
| Hourly | `snapper` | Create + cleanup timeline snapshots |
| Weekly (Sun) | `btrfs-balance` | `btrfs balance start -dusage=50 -musage=50 /` |
| Biweekly (Sun) | `cleanup` | `paccache -rk1` + clear `~/.cache` (preserves betterlockscreen/mpd/librewolf) |

## Requirements

- Artix Linux live ISO (or Arch-based live environment)
- Root access
- Internet connection
- Target disk (**will be completely destroyed**)

## Post-Install

After reboot:
1. DNS locked to localhost (dnsmasq → dnscrypt-proxy)
2. Fonts: HarmonyOS Sans (sans), JetBrains Mono Nerd Font (mono), Material Icons (icons), HarmonyOS Emoji Font some guy on telegram ripped for me (huawei please send me a cease and desist id love to frame it on my wall)
3. DPI auto-detected via xrandr → `~/.Xresources`
4. Services via runit: NetworkManager, iwd, dnsmasq, dnscrypt-proxy, elogind, openntpd, cronie, bluetoothd, acpid
5. Snapper hourly timeline snapshots + post-install snapshot
6. `jaiba` installed to `/usr/local/bin/jaiba`; config/themes in `~/.config/rama/`
7. Auto-starts X11 + Awesome on tty1 (fish or bash)
