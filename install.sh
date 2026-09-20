#!/usr/bin/env bash
#
# opinionated artix runit installer
# target: artix + runit + cachyos bore-lto kernel + limine + luks btrfs
# destructive. run from artix live as root.
#
# This script performs a complete automated installation of Artix Linux with:
# - runit init system (via artix-runit packages)
# - CachyOS bore-lto optimized kernel
# - Limine bootloader (UEFI + BIOS support)
# - LUKS2 encrypted root with Argon2id key derivation
# - Btrfs filesystem with subvolume layout (@, @home, @var, @cache, @log, @tmp, @swap, @snapshots)
# - Snapper for snapshot management with cron timers
# - NetworkManager + iwd + dnsmasq + dnscrypt-proxy for DNS
# - PipeWire audio stack
# - AwesomeWM window manager
# - Optional AUR packages via aura (built from source)
# - Custom Rust applications (jaiba - KeePass TUI)
#
# DESTRUCTIVE: This will completely wipe the selected disk. Run only from Artix live ISO as root.

set -Eeuo pipefail
IFS=$'\n\t'

# Script directory (where install.sh and assets live)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Temporary working directory for package lists, build artifacts, etc.
WORKDIR="/tmp/artix-install-work"
# Log file location (also tee'd to stdout)
LOG="/root/artix-install.log"
# Directory for limine assets (background images)
ASSETS_DIR="$SCRIPT_DIR/extra/limine-assets"
# Target mount point for installation
MOUNT="/mnt"

# Create work directories and start logging to both file and stdout
mkdir -p "$WORKDIR" "$ASSETS_DIR"
exec > >(tee -a "$LOG") 2>&1

# ============================================================================
# GLOBAL STATE VARIABLES
# ============================================================================
DISK=""                 # Target disk device (e.g., /dev/nvme0n1)
USERNAME=""             # Username for the primary user
HOSTNAME=""             # System hostname
TIMEZONE="America/Chicago"  # Default timezone
DNSMASQ_WHITELIST=1     # Whether to use dnsmasq domain whitelist (1=yes, 0=no)
USER_PASSWORD=""        # User + LUKS password (same for both)
SWAP_SIZE_GIB=0         # Swap size in GiB (0 = disabled)
SWAP_CREATED=0          # Flag: whether swapfile was successfully created
UEFI=0                  # Flag: UEFI boot detected (1) or BIOS (0)
SSD=0                   # Flag: target disk is SSD/NVMe (1) or HDD (0)
GPU="unknown"           # Detected GPU vendor: nvidia, amd, intel, or unknown
MICROCODE="intel-ucode" # CPU microcode package (intel-ucode or amd-ucode)
BOOT_PART=""            # Boot partition device path
ROOT_PART=""            # Root (LUKS) partition device path
LUKS_UUID=""            # UUID of the LUKS partition (for kernel cmdline)
INSTALL_SSH=1           # Whether to install openssh (1=yes, 0=no)
FAILED=()               # Array of failure messages for final report
CLEANED_UP=0            # Flag: cleanup already performed (prevents double-unmount)
AUR_JOBS=2              # aggregate build pressure cap; swap handles per-process peaks

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Print info message with prefix
info() { printf '==> %s\n' "$1"; }

# Print warning to stderr
warn() { printf 'warn: %s\n' "$1" >&2; }

# Print fatal error to stderr and exit
die() { printf 'fatal: %s\n' "$1" >&2; exit 1; }

# Trap ERR to show line number on any error
trap 'warn "error near line $LINENO"' ERR
# Trap EXIT to run cleanup on script termination (success or failure)
trap cleanup_on_exit EXIT

# Verify we're running as root (required for partitioning, mounting, chroot)
require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "run as root"
}

# Install packages needed on the live ISO before installation begins
ensure_live_packages() {
  info "ensuring live packages"
  pacman -Sy --noconfirm || die "cannot sync live pacman"

  # Packages required for partitioning, filesystems, encryption, bootloader, networking
  local pkgs=(
    curl ca-certificates parted btrfs-progs cryptsetup dosfstools e2fsprogs
    util-linux pciutils efibootmgr arch-install-scripts pacman-contrib rsync
  )
  local need=()
  local p
  for p in "${pkgs[@]}"; do
    # Check if package exists in repositories (pacman -Si succeeds)
    if pacman -Si "$p" >/dev/null 2>&1; then
      need+=("$p")
    fi
  done

  if ((${#need[@]})); then
    pacman -S --needed --noconfirm "${need[@]}" || warn "some live packages failed"
  fi
}

# Verify internet connectivity by checking Artix and CachyOS mirrors
check_internet() {
  info "checking internet"
  if ! curl -fsSI https://mirrors.artixlinux.org >/dev/null 2>&1; then
    if ! curl -fsSI https://mirror.cachyos.org >/dev/null 2>&1; then
      die "no internet"
    fi
  fi
}

# Rank pacman mirrors for faster downloads (uses rankmirrors from pacman-contrib)
rank_mirrors() {
  info "ranking mirrors"
  local list="/etc/pacman.d/mirrorlist"
  [[ -f "$list" ]] || return 0

  # Backup original mirrorlist with timestamp
  cp -a "$list" "${list}.bak.$(date +%s)"
  if command -v rankmirrors >/dev/null 2>&1; then
    # Select top 12 mirrors by speed
    if rankmirrors -n 12 "$list" > "${list}.new"; then
      if grep -q '^Server' "${list}.new"; then
        mv "${list}.new" "$list"
        pacman -Sy || true
      else
        rm -f "${list}.new"
        warn "rankmirrors produced empty mirrorlist, keeping old one"
      fi
    else
      warn "rankmirrors failed"
    fi
  else
    warn "rankmirrors not available"
  fi
}

# Detect GPU vendor and CPU microcode requirement
detect_hardware() {
  info "detecting hardware"

  # GPU detection via lspci
  if command -v lspci >/dev/null 2>&1; then
    if lspci -nn | grep -Eiq 'nvidia'; then
      GPU="nvidia"
    elif lspci -nn | grep -Eiq 'amd|radeon'; then
      GPU="amd"
    elif lspci -nn | grep -Eiq 'intel'; then
      GPU="intel"
    fi
  else
    warn "lspci missing, gpu detection skipped"
  fi

  # CPU microcode: AMD or Intel
  if grep -q AuthenticAMD /proc/cpuinfo; then
    MICROCODE="amd-ucode"
  else
    MICROCODE="intel-ucode"
  fi

  info "gpu: $GPU"
  info "microcode: $MICROCODE"
}

# Prompt user for installation parameters (username, hostname, swap, password, timezone, dnsmasq)
ask_user() {
  local input

  # Username: default "damien", validate POSIX username format
  read -rp "username [damien]: " input || die "eof/aborted"
  USERNAME="${input:-damien}"
  [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "bad username"

  # Hostname: default "artix", validate hostname format
  read -rp "hostname [artix]: " input || die "eof/aborted"
  HOSTNAME="${input:-artix}"
  [[ "$HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]] || die "bad hostname"

  # Swap size: default = RAM in GiB, user can override
  local ram_gib
  ram_gib="$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)"
  read -rp "swap size in GiB [${ram_gib}]: " input || die "eof/aborted"
  if [[ -z "$input" ]]; then
    SWAP_SIZE_GIB="$ram_gib"
  elif [[ "$input" =~ ^[0-9]+$ ]]; then
    SWAP_SIZE_GIB="$input"
  else
    die "swap size must be a number"
  fi

  # Password: prompt twice for confirmation (used for both user and LUKS)
  local p1 p2
  while true; do
    read -rsp "user + luks password: " p1 || die "eof/aborted"
    echo
    read -rsp "confirm password: " p2 || die "eof/aborted"
    echo
    if [[ -n "$p1" && "$p1" == "$p2" ]]; then
      USER_PASSWORD="$p1"
      break
    fi
    warn "passwords do not match or are empty"
  done

  # Timezone: validate against /usr/share/zoneinfo
  read -rp "timezone [America/Chicago]: " input || die "eof/aborted"
  if [[ "$input" =~ ^[A-Za-z0-9_+.-]+(/[A-Za-z0-9_+.-]+)*$ && "$input" != *..* && -f "/usr/share/zoneinfo/$input" ]]; then
    TIMEZONE="$input"
  elif [[ -n "$input" ]]; then
    warn "timezone '$input' not found, using America/Chicago"
    TIMEZONE="America/Chicago"
  fi

  # SSH: install and enable openssh (default yes)
  read -rp "install and enable openssh? [Y/n]: " input || die "eof/aborted"
  if [[ "$input" =~ ^[Nn]$ ]]; then
    INSTALL_SSH=0
  fi

  # dnsmasq whitelist: enable domain blocking (default yes)
  read -rp "enable dnsmasq whitelist (blocks non-whitelisted domains)? [Y/n]: " input || die "eof/aborted"
  if [[ "$input" =~ ^[Nn]$ ]]; then
    DNSMASQ_WHITELIST=0
  fi
}

# Interactive disk selection with validation
select_disk() {
  info "selecting disk"
  local disks=()
  # List block devices that are disks (not partitions), show name and size
  mapfile -t disks < <(lsblk -dpno NAME,SIZE,TYPE | awk '$3=="disk" {print $1" "$2}')
  ((${#disks[@]})) || die "no disks found"

  PS3="select disk to destroy: "
  select opt in "${disks[@]}"; do
    if [[ -n "${opt:-}" ]]; then
      DISK="${opt%% *}"
      break
    fi
  done

  [[ -b "$DISK" ]] || die "invalid disk"

  # Detect SSD vs HDD via rotational flag
  local base
  base="$(basename "$DISK")"
  if [[ "$(cat "/sys/block/$base/queue/rotational" 2>/dev/null || echo 1)" == "0" ]]; then
    SSD=1
  else
    SSD=0
  fi

  # Detect UEFI vs BIOS boot mode
  if [[ -d /sys/firmware/efi ]]; then
    UEFI=1
  else
    UEFI=0
  fi

  info "disk: $DISK"
  info "ssd: $SSD"
  info "uefi: $UEFI"
}

# Final confirmation before destructive partitioning
confirm_format() {
  printf '\n\e[1;31mWARNING: %s will be completely erased.\e[0m\n' "$DISK"
  printf '\e[1;31mLUKS + btrfs + new partitions will be written.\e[0m\n\n'
  read -rp "type YES to continue: " ans || die "eof/aborted"
  [[ "$ans" == "YES" ]] || die "aborted"
}

# Verify disk has at least 10 GiB free space
check_disk_space() {
  info "checking disk space"
  local disk_size_gib
  disk_size_gib="$(lsblk -bno SIZE "$DISK" 2>/dev/null | awk '{printf "%.0f", $1/1024/1024/1024}')"
  if [[ -z "$disk_size_gib" || "$disk_size_gib" -lt 10 ]]; then
    die "disk ${DISK} is too small (${disk_size_gib:-unknown}GiB), minimum is 10GiB"
  fi
  info "disk size: ${disk_size_gib}GiB"
}

# Check for existing/open LUKS container and close it if found
check_existing_luks() {
  info "checking for existing LUKS"
  # Close any pre-existing cryptroot
  if [[ -e /dev/mapper/cryptroot ]]; then
    warn "closing existing /dev/mapper/cryptroot"
    cryptsetup close cryptroot || true
  fi

  # Determine the root partition that partition_disk will create, so an
  # existing LUKS header can be reported before the destructive confirmation.
  local expected_root_part
  if [[ "$UEFI" -eq 1 ]]; then
    expected_root_part="$(part_path 2)"
  else
    expected_root_part="$(part_path 3)"
  fi

  if [[ -b "$expected_root_part" ]] && cryptsetup isLuks "$expected_root_part" 2>/dev/null; then
    warn "LUKS header detected on $expected_root_part — it will be wiped after confirmation"
  fi
}

# Get partition path accounting for NVMe (pN) vs SCSI (N) naming
part_path() {
  case "$DISK" in
    /dev/nvme*|/dev/mmcblk*)
      echo "${DISK}p$1"
      ;;
    *)
      echo "${DISK}$1"
      ;;
  esac
}

# Partition the disk: GPT + ESP/boot + LUKS root
partition_disk() {
  info "partitioning $DISK"
  # Wipe existing filesystem signatures
  wipefs -a "$DISK" || true
  # Create GPT partition table
  parted -s "$DISK" mklabel gpt

  if [[ "$UEFI" -eq 1 ]]; then
    # UEFI: 1 GiB ESP (fat32) + rest for LUKS root
    parted -s "$DISK" mkpart ESP fat32 1MiB 1025MiB
    parted -s "$DISK" set 1 esp on
    parted -s "$DISK" mkpart root 1025MiB 100%
    partprobe "$DISK" || warn "partprobe failed, relying on udev"
    sleep 2
    udevadm settle || true
    BOOT_PART="$(part_path 1)"
    ROOT_PART="$(part_path 2)"
  else
    # BIOS: 2 MiB bios_grub + 1 GiB ext4 boot + rest for LUKS root
    parted -s "$DISK" mkpart bios 1MiB 3MiB
    parted -s "$DISK" set 1 bios_grub on
    parted -s "$DISK" mkpart boot ext4 3MiB 1027MiB
    parted -s "$DISK" mkpart root 1027MiB 100%
    partprobe "$DISK" || warn "partprobe failed, relying on udev"
    sleep 2
    udevadm settle || true
    BOOT_PART="$(part_path 2)"
    ROOT_PART="$(part_path 3)"
  fi

  info "boot partition: $BOOT_PART"
  info "luks partition: $ROOT_PART"
}

# Create filesystems: format boot partition, LUKS2 encrypt root, create btrfs with subvolumes
setup_filesystems() {
  info "creating filesystems"

  # Format boot partition: FAT32 for UEFI, ext4 for BIOS
  if [[ "$UEFI" -eq 1 ]]; then
    mkfs.vfat -F32 -n ARTIXEFI "$BOOT_PART"
  else
    mkfs.ext4 -F -L artixboot "$BOOT_PART"
  fi

  # Create LUKS2 container with strong encryption parameters:
  # - aes-xts-plain64 cipher, 512-bit key
  # - sha512 hash, argon2id KDF (memory-hard, resistant to GPU cracking)
  printf '%s' "$USER_PASSWORD" | cryptsetup luksFormat \
    --type luks2 \
    --cipher aes-xts-plain64 \
    --key-size 512 \
    --hash sha512 \
    --pbkdf argon2id \
    --batch-mode \
    "$ROOT_PART"

  # Open LUKS container as /dev/mapper/cryptroot
  printf '%s' "$USER_PASSWORD" | cryptsetup open "$ROOT_PART" cryptroot
  # Store LUKS UUID for kernel command line
  LUKS_UUID="$(blkid -s UUID -o value "$ROOT_PART")"

  # Btrfs mount options: zstd:1 compression, noatime, v2 space cache
  # Add ssd option for TRIM/discard support on SSDs
  local opts="compress=zstd:1,noatime,space_cache=v2"
  if [[ "$SSD" -eq 1 ]]; then
    opts+=",ssd"
  fi

  # Create btrfs filesystem on decrypted device
  mkfs.btrfs -f /dev/mapper/cryptroot
  # Mount temporarily to create subvolumes
  mount -o "$opts" /dev/mapper/cryptroot "$MOUNT"

  # Create standard subvolume layout:
  # @          - root filesystem (/)
  # @home      - /home
  # @var       - /var
  # @cache     - /var/cache
  # @log       - /var/log
  # @tmp       - /var/tmp
  # @swap      - swapfile (no compression, no COW)
  # @snapshots - snapper snapshots
  local sub
  for sub in @ @home @var @cache @log @tmp @swap @snapshots; do
    btrfs subvolume create "$MOUNT/$sub"
  done

  umount "$MOUNT"

  # Mount subvolumes at their final locations
  mount -o "$opts,subvol=@" /dev/mapper/cryptroot "$MOUNT"
  mkdir -p "$MOUNT"/{boot,home,var,.snapshots,swap}

  mount -o "$opts,subvol=@home" /dev/mapper/cryptroot "$MOUNT/home"
  mount -o "$opts,subvol=@var" /dev/mapper/cryptroot "$MOUNT/var"
  mkdir -p "$MOUNT/var"/{cache,log,tmp}
  mount -o "$opts,subvol=@cache" /dev/mapper/cryptroot "$MOUNT/var/cache"
  mount -o "$opts,subvol=@log" /dev/mapper/cryptroot "$MOUNT/var/log"
  mount -o "$opts,subvol=@tmp" /dev/mapper/cryptroot "$MOUNT/var/tmp"
  # Swap subvolume: no compression, no COW for performance
  mount -o "compress=no,nodatacow,noatime,space_cache=v2,subvol=@swap" /dev/mapper/cryptroot "$MOUNT/swap"
  mount -o "$opts,subvol=@snapshots" /dev/mapper/cryptroot "$MOUNT/.snapshots"
  mount "$BOOT_PART" "$MOUNT/boot"
}

setup_swapfile() {
  if [[ "$SWAP_SIZE_GIB" -eq 0 ]]; then
    info "swapfile disabled by user"
    return 0
  fi

  # Remove existing swapfile if re-installing (only swapoff if actually active)
  local f="$MOUNT/swap/swapfile"
  if grep -qs "$f" /proc/swaps; then
    swapoff "$f" || true
  fi
  rm -f "$f"

  info "creating ${SWAP_SIZE_GIB}G swapfile"
  # Disable COW on swap directory and file
  chattr +C "$MOUNT/swap" || true
  truncate -s 0 "$f"
  chattr +C "$f"

  # NEVER fallocate on btrfs: it leaves prealloc/unwritten extents and swapon
  # dies with EINVAL at first boot. btrfs mkswapfile writes real extents and
  # sets nocow itself; dd is the portable fallback.
  if ! btrfs filesystem mkswapfile -s "${SWAP_SIZE_GIB}G" "$f" 2>/dev/null; then
    dd if=/dev/zero of="$f" bs=1M count=$((SWAP_SIZE_GIB * 1024)) status=progress || die "swapfile write failed"
  fi

  chmod 600 "$f"
  if mkswap "$f"; then
    SWAP_CREATED=1
    # activate NOW: rustc linking wasmtime (gram-git dep) peaks past free RAM
    # and gets OOM-killed without headroom. cleanup_umount already swapoffs
    # this exact path, so no leak.
    swapon "$f" || warn "swapon failed — rust builds may OOM"
  else
    warn "mkswap failed"
  fi
}

# Install base system using basestrap (Artix) or pacstrap (Arch)
strap_base() {
  info "strapping base system"

  # Base packages: base-devel for build tools, linux-firmware for hardware
  local pkgs=(base-devel linux-firmware)

  # Artix runit base meta-package (name varies by repo)
  if pacman -Si base-runit >/dev/null 2>&1; then
    pkgs+=(base-runit)
  elif pacman -Si artix-base-runit >/dev/null 2>&1; then
    pkgs+=(artix-base-runit)
  else
    pkgs+=(base)
  fi

  # Pin init + logind + iptables providers EXPLICITLY. Bare `elogind` makes
  # pacman prompt for init-logind providers and the default answer (1) is
  # elogind-dinit, which pulls dinit and conflicts with runit. Bare soname
  # dep libxtables.so likewise prompts; iptables is the sane default.
  # elogind-runit satisfies init-logind without any prompt.
  pkgs+=(runit elogind-runit iptables)

  # Use basestrap (Artix) if available, otherwise pacstrap (Arch).
  # No cross-fallback: on Artix pacstrap does not exist, and falling through
  # to it masks the real basestrap error (that bug cost a full debug cycle).
  if command -v basestrap >/dev/null 2>&1; then
    basestrap "$MOUNT" "${pkgs[@]}" || die "basestrap failed (see pacman output above)"
  elif command -v pacstrap >/dev/null 2>&1; then
    pacstrap "$MOUNT" "${pkgs[@]}" || die "pacstrap failed"
  else
    die "no basestrap or pacstrap"
  fi
}

# Generate fstab using fstabgen (Artix) or genfstab (Arch)
generate_fstab() {
  info "generating fstab"

  if command -v fstabgen >/dev/null 2>&1; then
    fstabgen -U "$MOUNT" > "$MOUNT/etc/fstab"
  elif command -v genfstab >/dev/null 2>&1; then
    genfstab -U "$MOUNT" > "$MOUNT/etc/fstab"
  else
    warn "no fstab generator found"
  fi

  # Add swapfile entry if created
  if [[ "$SWAP_CREATED" -eq 1 ]]; then
    if ! grep -q '/swap/swapfile' "$MOUNT/etc/fstab"; then
      echo '/swap/swapfile none swap defaults 0 0' >> "$MOUNT/etc/fstab"
    fi
  fi

  # Add tmpfs for /tmp (cleared on reboot, in RAM)
  if ! grep -q 'tmpfs /tmp tmpfs' "$MOUNT/etc/fstab"; then
    echo 'tmpfs /tmp tmpfs defaults,noatime,mode=1777 0 0' >> "$MOUNT/etc/fstab"
  fi
}

# Prepare chroot environment: bind mounts, resolv.conf, mirrorlist
prepare_chroot() {
  info "preparing chroot"

  # arch-chroot handles bind mounts automatically; manual fallback if missing
  if ! command -v arch-chroot >/dev/null 2>&1; then
    pacman -S --needed --noconfirm arch-install-scripts || true
  fi

  if ! command -v arch-chroot >/dev/null 2>&1; then
    local d
    for d in proc sys dev dev/pts run; do
      mkdir -p "$MOUNT/$d"
      mount --bind "/$d" "$MOUNT/$d" || true
    done
    if [[ -d /sys/firmware/efi/efivars ]]; then
      mkdir -p "$MOUNT/sys/firmware/efi/efivars"
      mount --bind /sys/firmware/efi/efivars "$MOUNT/sys/firmware/efi/efivars" || true
    fi
  fi

  mkdir -p "$MOUNT/etc"

  # Temporary DNS for installation (use public resolvers if host uses localhost)
  # Final localhost DNS is configured after AUR packages are installed
  if grep -Eq '^nameserver (127\.|::1)' /etc/resolv.conf 2>/dev/null; then
    printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' > "$MOUNT/etc/resolv.conf"
  elif [[ -f /etc/resolv.conf ]]; then
    cp -f /etc/resolv.conf "$MOUNT/etc/resolv.conf"
  else
    printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' > "$MOUNT/etc/resolv.conf"
  fi

  # Copy ranked mirrorlist to target
  if [[ -f /etc/pacman.d/mirrorlist ]]; then
    install -Dm644 /etc/pacman.d/mirrorlist "$MOUNT/etc/pacman.d/mirrorlist"
  fi
}

# Wrapper for arch-chroot or chroot (depending on availability)
chroot_raw() {
  if command -v arch-chroot >/dev/null 2>&1; then
    arch-chroot "$MOUNT" "$@"
  else
    chroot "$MOUNT" "$@"
  fi
}

# Execute a bash command string inside chroot with env
chroot_exec() {
  chroot_raw /usr/bin/env bash -lc "$1"
}

# Initialize pacman keyring in chroot and populate Artix/Arch keys
init_pacman_keys() {
  info "initializing pacman keys"
  chroot_raw pacman-key --init || die "pacman-key init failed"
  chroot_raw pacman-key --populate artix archlinux || true
  chroot_raw pacman-key --populate artix || true
  chroot_raw pacman-key --populate archlinux || true
}

# Add CachyOS optimized repositories without CachyOS system packages
configure_repos() {
  info "adding cachyos optimized repositories"

  local pacman_conf="$MOUNT/etc/pacman.conf"
  local mirrorlist_dir="$MOUNT/etc/pacman.d"
  [[ -f "$pacman_conf" ]] || die "pacman.conf not found in target"
  mkdir -p "$mirrorlist_dir"

  # Literal arch-tier paths, NOT $arch_v3/$arch_v4 variables: those variables
  # are only expanded by CachyOS's patched pacman. Artix ships stock pacman,
  # which would leave them unexpanded and fail the sync. $repo is standard
  # pacman and safe. znver4 sections reuse the x86_64_v4 path (per CachyOS
  # wiki); $repo distinguishes them.
  cat > "$mirrorlist_dir/cachyos-v3-mirrorlist" <<'EOF'
Server = https://cdn77.cachyos.org/repo/x86_64_v3/$repo
Server = https://us.cachyos.org/repo/x86_64_v3/$repo
Server = https://at.cachyos.org/repo/x86_64_v3/$repo
Server = https://mirror.cachyos.org/repo/x86_64_v3/$repo
EOF

  cat > "$mirrorlist_dir/cachyos-v4-mirrorlist" <<'EOF'
Server = https://cdn77.cachyos.org/repo/x86_64_v4/$repo
Server = https://us.cachyos.org/repo/x86_64_v4/$repo
Server = https://at.cachyos.org/repo/x86_64_v4/$repo
Server = https://mirror.cachyos.org/repo/x86_64_v4/$repo
EOF

  local loader="/lib/ld-linux-x86-64.so.2"
  if [[ ! -x "$loader" && -x "/usr/lib/ld-linux-x86-64.so.2" ]]; then
    loader="/usr/lib/ld-linux-x86-64.so.2"
  fi

  local tier=""
  if command -v gcc >/dev/null 2>&1 && gcc -march=native -Q --help=target 2>&1 | grep -E '^[[:space:]]*-march=' | grep -Eq '[[:space:]]znver[45]([[:space:]]|$)'; then
    tier="znver4"
  elif [[ -x "$loader" ]] && "$loader" --help 2>&1 | grep -Fq 'x86-64-v4 (supported, searched)'; then
    tier="v4"
  elif [[ -x "$loader" ]] && "$loader" --help 2>&1 | grep -Fq 'x86-64-v3 (supported, searched)'; then
    tier="v3"
  else
    warn "cpu does not support a CachyOS optimized repository tier; using Artix packages"
    return 0
  fi

  info "selected cachyos repository tier: $tier"

  # The [cachyos] repository contains CachyOS system packages, including its
  # pacman fork. Import the signing key directly and leave that repository out.
  local cachyos_key="F3B607488DB35A47"
  chroot_raw pacman-key --recv-keys "$cachyos_key" --keyserver keyserver.ubuntu.com || die "failed to import CachyOS signing key"
  chroot_raw pacman-key --lsign-key "$cachyos_key" || die "failed to sign CachyOS key locally"

  local backup="$pacman_conf.pre-cachyos"
  if [[ ! -e "$backup" ]]; then
    cp -a "$pacman_conf" "$backup"
  fi

  local tmp="$pacman_conf.cachyos.new"
  awk -v tier="$tier" '
    function is_section(line) {
      return line ~ /^\[[^]]+\]$/
    }

    function is_artix_repo(line) {
      return line ~ /^\[(system|world|galaxy|lib32|system-gremlins|world-gremlins|galaxy-gremlins|lib32-gremlins|system-goblins|world-goblins|galaxy-goblins|lib32-goblins)\]$/
    }

    function is_cachyos_repo(line) {
      return line ~ /^\[(cachyos|cachyos-v3|cachyos-core-v3|cachyos-extra-v3|cachyos-v4|cachyos-core-v4|cachyos-extra-v4|cachyos-znver4|cachyos-core-znver4|cachyos-extra-znver4)\]$/
    }

    function emit_repos() {
      print ""
      print "# CachyOS optimized repositories"
      print "# [cachyos] is intentionally omitted; it contains CachyOS system packages."
      if (tier == "znver4") {
        print "[cachyos-znver4]"
        print "Include = /etc/pacman.d/cachyos-v4-mirrorlist"
        print ""
        print "[cachyos-core-znver4]"
        print "Include = /etc/pacman.d/cachyos-v4-mirrorlist"
        print ""
        print "[cachyos-extra-znver4]"
        print "Include = /etc/pacman.d/cachyos-v4-mirrorlist"
      } else if (tier == "v4") {
        print "[cachyos-v4]"
        print "Include = /etc/pacman.d/cachyos-v4-mirrorlist"
        print ""
        print "[cachyos-core-v4]"
        print "Include = /etc/pacman.d/cachyos-v4-mirrorlist"
        print ""
        print "[cachyos-extra-v4]"
        print "Include = /etc/pacman.d/cachyos-v4-mirrorlist"
      } else {
        print "[cachyos-v3]"
        print "Include = /etc/pacman.d/cachyos-v3-mirrorlist"
        print ""
        print "[cachyos-core-v3]"
        print "Include = /etc/pacman.d/cachyos-v3-mirrorlist"
        print ""
        print "[cachyos-extra-v3]"
        print "Include = /etc/pacman.d/cachyos-v3-mirrorlist"
      }
    }

    BEGIN {
      inserted = 0
      in_cachyos = 0
      skip_cachyos_comment = 0
      saw_artix = 0
    }

    {
      # Stock pacman does not infer v3/v4 from "auto"; list every tier arch
      # explicitly so tier-tagged packages are accepted.
      if ($0 ~ /^Architecture[[:space:]]*=/) {
        $0 = "Architecture = x86_64 x86_64_v3 x86_64_v4 x86_64-znver4"
      }

      if ($0 == "# CachyOS optimized repositories") {
        skip_cachyos_comment = 1
        next
      }
      if (skip_cachyos_comment) {
        if ($0 == "" || $0 ~ /^# \[cachyos\] is intentionally omitted/) {
          next
        }
        skip_cachyos_comment = 0
      }

      if (is_section($0)) {
        if (in_cachyos) {
          in_cachyos = 0
        }

        if (is_cachyos_repo($0)) {
          in_cachyos = 1
          next
        }

        if (is_artix_repo($0)) {
          saw_artix = 1
        } else if (saw_artix && !inserted) {
          emit_repos()
          inserted = 1
        } else if (!saw_artix && !inserted && $0 != "[options]") {
          emit_repos()
          inserted = 1
        }
      } else if (in_cachyos) {
        next
      }

      print
    }

    END {
      if (!inserted) {
        emit_repos()
      }
    }
  ' "$pacman_conf" > "$tmp" || die "failed to update pacman.conf"

  mv "$tmp" "$pacman_conf"

  if grep -Eq '^\[(cachyos|cachyos-core|cachyos-extra)\]$' "$pacman_conf"; then
    die "custom CachyOS system repository found in pacman.conf"
  fi

  # Sync databases after the key and repository configuration are complete.
  chroot_raw pacman -Sy || die "failed to sync pacman databases"

  local primary_repo
  case "$tier" in
    znver4) primary_repo="cachyos-znver4" ;;
    v4) primary_repo="cachyos-v4" ;;
    v3) primary_repo="cachyos-v3" ;;
  esac
  chroot_raw pacman -Sl "$primary_repo" >/dev/null 2>&1 || die "CachyOS repository is unavailable: $primary_repo"
}

# Refresh package list cache for install_pkgs/install_first_found to use
refresh_pkglist() {
  info "refreshing package list cache"
  chroot_raw pacman -Slq | sort -u > "$WORKDIR/pkglist" || true
  if [[ ! -s "$WORKDIR/pkglist" ]]; then
    warn "package list is empty"
  fi
}

# Install packages that exist in the package list (filters unavailable ones)
install_pkgs() {
  local available=()
  local p

  for p in "$@"; do
    if grep -Fxq "$p" "$WORKDIR/pkglist" 2>/dev/null; then
      available+=("$p")
    else
      warn "package not found: $p"
    fi
  done

  if ((${#available[@]} == 0)); then
    return 0
  fi

  if ! chroot_raw pacman -S --needed --noconfirm "${available[@]}"; then
    warn "failed to install: ${available[*]}"
    # Force space separation regardless of global IFS
    local failed_pkgs
    failed_pkgs="$(IFS=" "; echo "${available[*]}")"
    FAILED+=("pacman: $failed_pkgs")
    return 1
  fi
}

# Try to install the first available package from a list (for alternatives)
install_first_found() {
  local p
  for p in "$@"; do
    if grep -Fxq "$p" "$WORKDIR/pkglist" 2>/dev/null; then
      install_pkgs "$p"
      return $?
    fi
  done
  return 1
}

# Install all official repository packages by category
install_official_packages() {
  info "installing kernel"
  # CachyOS bore-lto optimized kernel (fallback chain)
  install_first_found linux-cachyos-bore-lto linux-cachyos-bore linux-cachyos linux || die "no kernel found"
  install_first_found linux-cachyos-bore-lto-headers linux-cachyos-bore-headers linux-cachyos-headers linux-headers || true
  install_pkgs mkinitcpio || true

  info "installing core utilities"
  install_pkgs \
    sudo cryptsetup btrfs-progs dosfstools e2fsprogs util-linux pciutils \
    curl wget git rsync vim nano fish bash-completion man-db man-pages \
    openssl pkgconf python rustup || true

  info "installing runit service packages"
  install_pkgs \
    artix-runit dbus-runit elogind-runit networkmanager-runit iwd-runit \
    bluez-runit bluetooth-runit cronie-runit dnsmasq-runit dnscrypt-proxy-runit \
    acpid-runit openntpd-runit || true

  info "installing network stack"
  install_pkgs networkmanager iwd dnsmasq dnscrypt-proxy || true
  install_pkgs networkmanager-iwd || true
  install_pkgs openntpd || true

  info "installing pipewire"
  install_pkgs \
    pipewire pipewire-alsa pipewire-audio pipewire-pulse pipewire-jack \
    wireplumber gst-plugin-pipewire rtkit libpulse || true

  info "installing xorg"
  install_pkgs \
    xorg-server xorg-xinit xorg-xrandr xorg-xsetroot xorg-xinput xorg-xrdb \
    xorg-xkill xorg-xdpyinfo xterm xorg-fonts-misc ttf-dejavu || true

  info "installing wm + lua"
  install_pkgs awesome lua lua53 luarocks || install_pkgs awesome lua luarocks || true

  info "installing desktop apps from official repos"
  install_pkgs \
    thunar kitty obs-studio btop gimp bluez bluez-utils blueberry \
    sct argyllcms dispwin xdg-utils xdg-user-dirs gvfs tumbler polkit fontconfig eza || true

  info "installing music stack (official repos)"
  install_pkgs mpd ncmpcpp starship || true

  info "installing gpu/cpu hardware packages"
  install_pkgs mesa vulkan-icd-loader || true
  install_pkgs "$MICROCODE" || true

  # GPU-specific packages
  case "$GPU" in
    nvidia)
      # If using CachyOS kernel, try matching nvidia kernel module packages
      if ls "$MOUNT"/boot/vmlinuz-linux-cachyos* >/dev/null 2>&1; then
        if ! install_first_found \
          linux-cachyos-bore-lto-nvidia \
          linux-cachyos-bore-nvidia \
          linux-cachyos-nvidia; then
          install_pkgs nvidia-dkms || true
        fi
      else
        install_pkgs nvidia-dkms linux-headers || true
      fi
      install_pkgs nvidia-utils nvidia-settings libvdpau || true
      ;;
    amd)
      install_pkgs vulkan-radeon libva-mesa-driver mesa-vdpau vulkan-mesa-layers || true
      ;;
    intel)
      install_pkgs vulkan-intel intel-media-driver libva-intel-driver || true
      ;;
  esac

  info "installing bootloader packages"
  install_pkgs limine efibootmgr || true

  info "installing snapshot + cron packages"
  install_pkgs snapper cronie || true
}

# Configure locale, hostname, keymap, and hosts file
configure_locale_hostname() {
  info "configuring locale/hostname"

  # Enable US English and Chinese locales
  sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' "$MOUNT/etc/locale.gen" || true
  sed -i 's/^#zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' "$MOUNT/etc/locale.gen" || true
  chroot_raw locale-gen || true

  # System locale: English messages, Chinese time format
  cat > "$MOUNT/etc/locale.conf" <<EOF
LANG=en_US.UTF-8
LC_MESSAGES=en_US.UTF-8
LC_TIME=zh_CN.UTF-8
EOF
  echo 'KEYMAP=us' > "$MOUNT/etc/vconsole.conf"
  echo "$HOSTNAME" > "$MOUNT/etc/hostname"

  # /etc/hosts with localhost and hostname entries
  cat > "$MOUNT/etc/hosts" <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 $HOSTNAME.localdomain $HOSTNAME
EOF
}

# Configure system fonts: emoji + material design icons + fontconfig aliases
configure_fonts() {
  info "configuring system fonts"

  # Copy Noto Color Emoji if available
  mkdir -p "$MOUNT/usr/share/fonts/emoji"
  if [[ -f "$SCRIPT_DIR/extra/fonts/emoji/NotoColorEmoji.ttf" ]]; then
    cp "$SCRIPT_DIR/extra/fonts/emoji/NotoColorEmoji.ttf" "$MOUNT/usr/share/fonts/emoji/"
  else
    warn "fonts/emoji/NotoColorEmoji.ttf not found, emoji font skipped"
  fi

  # Copy Material Design Icons if available
  mkdir -p "$MOUNT/usr/share/fonts/material-design-icons"
  local md_fonts=(
    "$SCRIPT_DIR/extra/fonts/material-design-icons/MaterialIcons-Regular.ttf"
    "$SCRIPT_DIR/extra/fonts/material-design-icons/MaterialIconsOutlined-Regular.otf"
    "$SCRIPT_DIR/extra/fonts/material-design-icons/MaterialIconsRound-Regular.otf"
    "$SCRIPT_DIR/extra/fonts/material-design-icons/MaterialIconsSharp-Regular.otf"
    "$SCRIPT_DIR/extra/fonts/material-design-icons/MaterialIconsTwoTone-Regular.otf"
  )
  local md_font_copied=0
  local f
  for f in "${md_fonts[@]}"; do
    if [[ -f "$f" ]]; then
      cp "$f" "$MOUNT/usr/share/fonts/material-design-icons/"
      md_font_copied=1
    fi
  done
  if [[ "$md_font_copied" -eq 1 ]]; then
    info "material design icons installed"
  else
    warn "material-design-icons/ not found, material icons skipped"
  fi

  # Fontconfig: prefer HarmonyOS Sans for sans-serif, JetBrains Mono Nerd Font for monospace
  # Material Icons variants are installed locally and discovered automatically by fontconfig
  cat > "$MOUNT/etc/fonts/conf.d/50-fonts.conf" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <alias>
    <family>sans-serif</family>
    <prefer>
      <family>HarmonyOS Sans</family>
    </prefer>
  </alias>
  <alias>
    <family>monospace</family>
    <prefer>
      <family>JetBrains Mono Nerd Font</family>
    </prefer>
  </alias>
</fontconfig>
EOF

  chroot_raw fc-cache -f || warn "fc-cache failed"
}

# Configure mkinitcpio with GPU modules and encrypt hook for LUKS
configure_mkinitcpio() {
  info "configuring mkinitcpio"

  # Add NVIDIA modules to initramfs if NVIDIA GPU (for early KMS)
  local modules=""
  if [[ "$GPU" == "nvidia" ]]; then
    modules="nvidia nvidia_modeset nvidia_uvm nvidia_drm"
  fi

  # Hooks: base udev autodetect keyboard keymap modconf block encrypt filesystems fsck
  # encrypt hook prompts for LUKS password at boot
  cat > "$MOUNT/etc/mkinitcpio.conf" <<EOF
MODULES=($modules)
BINARIES=()
FILES=()
HOOKS=(base udev autodetect keyboard keymap modconf block encrypt filesystems fsck)
EOF

  chroot_raw mkinitcpio -P || warn "mkinitcpio failed"
}

# Configure snapper for btrfs snapshots with hourly timeline and weekly cleanup
configure_snapper() {
  info "configuring snapper"
  mkdir -p "$MOUNT/etc/snapper/configs"

  # Snapper config for root subvolume
  cat > "$MOUNT/etc/snapper/configs/root" <<'EOF'
SUBVOLUME="/"
FSTYPE="btrfs"
QGROUP=""
SPACE_LIMIT="0.5"
FREE_LIMIT="0.2"
ALLOW_USERS=""
ALLOW_GROUPS=""
SYNC_ACL="no"
BACKGROUND_COMPARISON="yes"
NUMBER_CLEANUP="yes"
NUMBER_LIMIT="10"
NUMBER_LIMIT_IMPORTANT="5"
NUMBER_MIN_AGE="1800"
TIMELINE_CREATE="yes"
TIMELINE_CLEANUP="yes"
TIMELINE_LIMIT_HOURLY="0"
TIMELINE_LIMIT_DAILY="7"
TIMELINE_LIMIT_WEEKLY="0"
TIMELINE_LIMIT_MONTHLY="0"
TIMELINE_LIMIT_YEARLY="0"
EMPTY_PRE_POST_CLEANUP="yes"
EMPTY_PRE_POST_MIN_AGE="1800"
EOF

  # Hourly cron: create timeline snapshot + cleanup old timeline snapshots
  mkdir -p "$MOUNT/etc/cron.hourly"
  cat > "$MOUNT/etc/cron.hourly/snapper" <<'EOF'
#!/bin/sh
/usr/bin/snapper -c root create --description timeline --cleanup-algorithm timeline >/dev/null 2>&1 || true
/usr/bin/snapper -c root cleanup timeline >/dev/null 2>&1 || true
EOF
  chmod +x "$MOUNT/etc/cron.hourly/snapper"

  # Weekly cron: btrfs balance to reclaim space (runs Sunday)
  mkdir -p "$MOUNT/etc/cron.weekly"
  cat > "$MOUNT/etc/cron.weekly/btrfs-balance" <<'EOF'
#!/bin/sh
# Run btrfs balance on root filesystem weekly (Sunday)
# Usage: btrfs balance start -dusage=50 -musage=50 /
/usr/bin/btrfs balance start -dusage=50 -musage=50 / >/dev/null 2>&1 || true
EOF
  chmod +x "$MOUNT/etc/cron.weekly/btrfs-balance"

  # Biweekly cleanup (every other Sunday): paccache + clean user caches
  cat > "$MOUNT/etc/cron.weekly/cleanup" <<'EOF'
#!/bin/sh
# Biweekly cleanup (runs every other Sunday)
# Keep 1 package version, clear ~/.cache except betterlockscreen/mpd/librewolf

# Only run on even weeks (week number % 2 == 0)
week=$(date +%U)
if [ $((week % 2)) -ne 0 ]; then
  exit 0
fi

# paccache - keep 1 version of installed packages, remove all uninstalled
/usr/bin/paccache -rk1 >/dev/null 2>&1 || true

# Clean user cache dirs, preserving specific folders
for home in /home/*; do
  [ -d "$home/.cache" ] || continue
  user=$(basename "$home")
  # Skip system users
  id "$user" >/dev/null 2>&1 || continue

  find "$home/.cache" -mindepth 1 -maxdepth 1 \( \
    -name 'betterlockscreen' -o \
    -name 'mpd' -o \
    -name 'librewolf' \
  \) -prune -o -print0 | xargs -0r rm -rf 2>/dev/null || true
done
EOF
  chmod +x "$MOUNT/etc/cron.weekly/cleanup"
}

# Configure NetworkManager, iwd, dnsmasq, and dnscrypt-proxy
configure_network() {
  info "configuring networkmanager + iwd + dns"

  mkdir -p "$MOUNT/etc/NetworkManager/conf.d"

  # NetworkManager: disable built-in DNS (dns=none), unmanaged rc-manager, keyfile plugin
  # Only manage non-loopback interfaces
  cat > "$MOUNT/etc/NetworkManager/NetworkManager.conf" <<'EOF'
[main]
dns=none
rc-manager=unmanaged
plugins=keyfile

[keyfile]
unmanaged-devices=interface-name:lo
EOF

  # Use iwd as WiFi backend instead of wpa_supplicant
  cat > "$MOUNT/etc/NetworkManager/conf.d/99-iwd.conf" <<'EOF'
[device]
wifi.backend=iwd
EOF

  # dnsmasq.d directory for drop-in configs
  mkdir -p "$MOUNT/etc/dnsmasq.d"
  cat > "$MOUNT/etc/dnsmasq.d/99-placeholder.conf" <<'EOF'
# drop your dnsmasq config here.
# example:
# no-resolv
# listen-address=127.0.0.1
# server=127.0.0.2#5353
EOF

  # DNSMASQ_WHITELIST mode: use custom dnsmasq.conf with domain whitelist
  if [[ "$DNSMASQ_WHITELIST" -eq 1 ]]; then
    if [[ -f "$SCRIPT_DIR/extra/network/dnsmasq.conf" ]]; then
      cp "$SCRIPT_DIR/extra/network/dnsmasq.conf" "$MOUNT/etc/dnsmasq.conf"
      # Ensure conf-dir is included for drop-in configs
      if ! grep -q '^conf-dir=/etc/dnsmasq.d' "$MOUNT/etc/dnsmasq.conf"; then
        echo 'conf-dir=/etc/dnsmasq.d,.conf' >> "$MOUNT/etc/dnsmasq.conf"
      fi
      info "dnsmasq whitelist enabled"
    else
      warn "network/dnsmasq.conf not found, using minimal config"
      DNSMASQ_WHITELIST=0
    fi
  fi

  # Default mode: dnsmasq forwards all queries to dnscrypt-proxy on port 5354
  if [[ "$DNSMASQ_WHITELIST" -eq 0 ]]; then
    cat > "$MOUNT/etc/dnsmasq.conf" <<'EOF'
no-resolv
server=127.0.0.1#5354
server=[::1]#5354
listen-address=127.0.0.1
listen-address=::1
conf-dir=/etc/dnsmasq.d,.conf
EOF
    info "dnsmasq whitelist disabled — forwarding all queries to dnscrypt-proxy"
  fi

  # dnscrypt-proxy: copy custom config or retune the shipped one.
  # Port contract: dnsmasq above forwards to 127.0.0.1#5354. The package
  # default toml listens on 127.0.0.1:53, which collides with dnsmasq and
  # leaves the forward target dead → no DNS at boot. Fix the port here.
  mkdir -p "$MOUNT/etc/dnscrypt-proxy"
  local dcp="$MOUNT/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
  if [[ -f "$SCRIPT_DIR/extra/network/dnscrypt-proxy.toml" ]]; then
    cp "$SCRIPT_DIR/extra/network/dnscrypt-proxy.toml" "$dcp"
    if ! grep -q '127.0.0.1:5354' "$dcp"; then
      warn "custom dnscrypt-proxy.toml does not listen on 127.0.0.1:5354 — dnsmasq forward will fail"
    fi
  elif [[ -f "$dcp" ]]; then
    sed -i "s|^listen_addresses = .*|listen_addresses = ['127.0.0.1:5354']|" "$dcp"
  else
    cat > "$dcp" <<'EOF'
# fallback placeholder: dnscrypt-proxy package config was missing.
# dnsmasq forwards to this port; add real server config or DNS stays dead.
listen_addresses = ['127.0.0.1:5354']
EOF
    warn "dnscrypt-proxy package config missing — placeholder written, DNS will not resolve until configured"
  fi
}

# Configure NTP (openntpd) and timezone
configure_ntp() {
  info "configuring ntp (openntpd)"

  # openntpd config: pool.ntp.org, slew-only time correction
  cat > "$MOUNT/etc/ntpd.conf" <<'EOF'
pool pool.ntp.org
offset_correction_interval yes
slew only
EOF

  # Set timezone symlink
  if [[ -f "$MOUNT/usr/share/zoneinfo/$TIMEZONE" ]]; then
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$MOUNT/etc/localtime"
  else
    warn "zoneinfo missing in chroot for $TIMEZONE, leaving localtime as-is"
  fi
}

# Install and optionally enable openssh
install_ssh() {
  if [[ "$INSTALL_SSH" -eq 0 ]]; then
    info "skipping openssh"
    return 0
  fi
  info "installing openssh"
  # Artix splits runit service dirs into -runit packages; without
  # openssh-runit there is no /etc/sv/sshd to enable.
  install_pkgs openssh openssh-runit || warn "openssh install failed"
  enable_service sshd || true
}

# Configure ufw firewall: deny incoming, allow outgoing, allow SSH if enabled
configure_firewall() {
  info "configuring ufw firewall"
  # ufw-runit provides the /etc/sv/ufw service dir (see openssh-runit note)
  install_pkgs ufw ufw-runit || { warn "ufw install failed"; return 1; }

  chroot_raw ufw --force enable || warn "ufw enable failed"
  chroot_raw ufw default deny incoming || true
  chroot_raw ufw default allow outgoing || true
  if [[ "$INSTALL_SSH" -eq 1 ]]; then
    chroot_raw ufw allow ssh || true
  fi
  enable_service ufw || true
}

# Clean pacman package cache (keep 1 version of each package)
cleanup_pacman_cache() {
  info "cleaning pacman cache"
  chroot_raw paccache -rk1 || warn "paccache failed"
}

# Create pacman hook to reinstall limine boot files on kernel updates
create_limine_hook() {
  info "creating limine kernel update hook"

  mkdir -p "$MOUNT/etc/pacman.d/hooks"

  # Hook triggers on kernel/initramfs file changes in /boot
  cat > "$MOUNT/etc/pacman.d/hooks/limine.hook" <<'EOF'
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Target = boot/vmlinuz*
Target = boot/initramfs*

[Action]
Description = Reinstalling limine boot files...
When = PostTransaction
Exec = /usr/local/bin/limine-kernel-update.sh
EOF

  # Hook script: reinstall limine to disk/ESP
  cat > "$MOUNT/usr/local/bin/limine-kernel-update.sh" <<'EOF'
#!/bin/sh
# Reinstall limine boot files after kernel update
# Called by pacman hook on kernel/initramfs upgrades

DISK=""
# Detect boot disk from current root
if [ -f /proc/cmdline ]; then
  # Parse cryptdevice=UUID= from cmdline to find the physical disk
  LUKS_UUID=$(sed -n 's/.*cryptdevice=UUID=\([^:]*\):.*/\1/p' /proc/cmdline)
  PART=$(blkid -U "$LUKS_UUID" 2>/dev/null)
  DISK=$(lsblk -no PKNAME "$PART" 2>/dev/null | head -1)
fi

if [ -z "$DISK" ]; then
  # Fallback: try to find from limine.conf or just exit
  echo "Could not determine boot disk, skipping limine reinstall"
  exit 0
fi

if [ -d /sys/firmware/efi ]; then
  # UEFI: copy EFI binary and config to ESP
  EFI_BIN=$(find /usr/share/limine -maxdepth 1 -name '*.efi' 2>/dev/null | head -1)
  if [ -n "$EFI_BIN" ]; then
    ESP="/boot"
    mkdir -p "$ESP/EFI/limine" "$ESP/EFI/BOOT"
    cp "$EFI_BIN" "$ESP/EFI/limine/limine.efi"
    cp "$EFI_BIN" "$ESP/EFI/BOOT/BOOTX64.EFI"
    # ship config to both locations for limine version compatibility
    [ -f "$ESP/limine/limine.conf" ] && cp "$ESP/limine/limine.conf" "$ESP/limine.conf"
    [ -f "$ESP/limine/limine.conf" ] && cp "$ESP/limine/limine.conf" "$ESP/EFI/limine/limine.conf"
    echo "Limine EFI reinstalled"
  fi
else
  # BIOS: reinstall to MBR
  limine bios-install "$DISK"
  echo "Limine BIOS reinstalled on $DISK"
fi
EOF

  chmod +x "$MOUNT/usr/local/bin/limine-kernel-update.sh"
}

# Verify time synchronization is working
verify_timesync() {
  info "verifying time synchronization"
  if chroot_raw ntpctl -s 2>/dev/null; then
    info "time synchronized"
  else
    warn "time sync status unknown — verify openntpd is running"
  fi
}

# Offer to clean up AUR build artifacts (source + build dirs)
cleanup_aur_builds() {
  info "cleaning aur build artifacts"
  if [[ -t 0 ]]; then
    read -rp "remove aura/jaiba source and build dirs (~/src)? [Y/n]: " input || input="n"
  else
    info "non-interactive terminal: keeping ~/src"
    return 0
  fi

  if [[ "$input" =~ ^[Nn]$ ]]; then
    info "keeping ~/src"
    return 0
  fi
  chroot_raw rm -rf "/home/$USERNAME/src" || warn "failed to remove ~/src"
  info "removed ~/src"
}

# Update system using aura (AUR helper)
system_update() {
  info "updating system via aura"
  if ! chroot_raw aura --version >/dev/null 2>&1; then
    warn "aura unavailable, skipping system update"
    return 0   # was: return 1 — under set -e that aborted the install at 99%
  fi
  chroot_exec "sudo -u $USERNAME bash -lc 'aura -Syyu --noconfirm'" || warn "aura -Syyu failed"
  return 0
}

# Enable a runit service by symlinking to runsvdir/default
# Tries multiple possible service directory names (e.g., dbus vs dbus-1)
enable_service() {
  local candidates=("$@")
  local name dir

  mkdir -p "$MOUNT/etc/runit/runsvdir/default"

  for name in "${candidates[@]}"; do
    for dir in "$MOUNT/etc/runit/sv/$name" "$MOUNT/etc/sv/$name"; do
      if [[ -d "$dir" ]]; then
        ln -sfn "${dir#$MOUNT}" "$MOUNT/etc/runit/runsvdir/default/$name"
        return 0
      fi
    done
  done

  warn "no runit service found for: $*"
  return 1
}

# Enable all required runit services
enable_services() {
  info "enabling runit services"
  mkdir -p "$MOUNT/etc/runit/runsvdir/default"

  # Remove wpa_supplicant if present (we use iwd)
  rm -f "$MOUNT/etc/runit/runsvdir/default/wpa_supplicant"

  # Core services (with fallback names for different package naming)
  enable_service dbus dbus-1 || true
  enable_service elogind || true
  enable_service NetworkManager networkmanager || true
  enable_service iwd || true
  enable_service bluetoothd bluetooth || true
  enable_service cronie crond cron || true
  enable_service dnsmasq || true
  enable_service dnscrypt-proxy || true
  enable_service acpid || true
  enable_service openntpd || true
}

# Configure Limine bootloader (UEFI and BIOS)
configure_bootloader() {
  info "configuring limine"

  local kernel_path initrd_path kernel_file initrd_file ucode_file=""
  kernel_path="$(ls "$MOUNT"/boot/vmlinuz-*cachyos* 2>/dev/null | head -n1 || true)"
  if [[ -z "$kernel_path" ]]; then
    kernel_path="$(ls "$MOUNT"/boot/vmlinuz-* 2>/dev/null | head -n1 || true)"
  fi
  [[ -n "$kernel_path" ]] || die "no kernel found in /boot"
  kernel_file="$(basename "$kernel_path")"

  initrd_path="$(ls "$MOUNT"/boot/initramfs-*cachyos*.img 2>/dev/null | grep -v fallback | head -n1 || true)"
  if [[ -z "$initrd_path" ]]; then
    initrd_path="$(ls "$MOUNT"/boot/initramfs-*.img 2>/dev/null | grep -v fallback | head -n1 || true)"
  fi
  if [[ -z "$initrd_path" ]]; then
    chroot_raw mkinitcpio -P || true
    initrd_path="$(ls "$MOUNT"/boot/initramfs-*.img 2>/dev/null | grep -v fallback | head -n1 || true)"
  fi
  [[ -n "$initrd_path" ]] || die "no initramfs found"
  initrd_file="$(basename "$initrd_path")"

  if [[ -f "$MOUNT/boot/$MICROCODE.img" ]]; then
    ucode_file="$MICROCODE.img"
  fi

  local cmdline="cryptdevice=UUID=$LUKS_UUID:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw"
  if [[ "$GPU" == "nvidia" ]]; then
    cmdline+=" nvidia_drm.modeset=1"
  fi

  mkdir -p "$MOUNT/boot/limine"

  local wall_src="" wall_dest_name="" wall_line=""
  if [[ -f "$ASSETS_DIR/black.bmp" ]]; then
    wall_src="$ASSETS_DIR/black.bmp"; wall_dest_name="black.bmp"
  elif [[ -f "$ASSETS_DIR/black.png" ]]; then
    wall_src="$ASSETS_DIR/black.png"; wall_dest_name="black.png"
  fi
  if [[ -n "$wall_src" ]]; then
    cp "$wall_src" "$MOUNT/boot/limine/$wall_dest_name"
    wall_line="wallpaper: boot():/limine/$wall_dest_name"
  fi

  local ucode_line=""
  if [[ -n "$ucode_file" ]]; then
    ucode_line="    module_path: boot():/$ucode_file"
  fi

  # timeout 5 + default 0 while debugging: menu visible, valid index.
  # flip timeout to 0 once you've seen it boot once.
  cat > "$MOUNT/boot/limine/limine.conf" <<EOF
timeout: 5
default: 0
$wall_line

:CachyOS Artix
    protocol: linux
    kernel_path: boot():/$kernel_file
    cmdline: $cmdline
$ucode_line
    module_path: boot():/$initrd_file
EOF

  # self-check: a config with no entry line or missing kernel/initrd on the
  # ESP boots to exactly the "no valid entries" screen. fail loud here instead.
  if ! grep -q '^:' "$MOUNT/boot/limine/limine.conf" \
     || ! grep -q 'kernel_path:' "$MOUNT/boot/limine/limine.conf"; then
    die "limine.conf has no boot entry — heredoc mangled?"
  fi
  [[ -f "$MOUNT/boot/$kernel_file" ]]  || die "kernel $kernel_file not on ESP"
  [[ -f "$MOUNT/boot/$initrd_file" ]]  || die "initramfs $initrd_file not on ESP"
  local cf
  for cf in "$MOUNT/boot/limine.conf" "$MOUNT/boot/EFI/limine/limine.conf"; do
    grep -q '^:' "$cf" || die "copied config missing entry: $cf"
  done

  if [[ "$UEFI" -eq 1 ]]; then
    # explicit arch-named binary; never find|head over *.efi
    local efi_name
    case "$(uname -m)" in
      aarch64) efi_name="BOOTAA64.EFI" ;;
      riscv64) efi_name="BOOTRISCV64.EFI" ;;
      *)       efi_name="BOOTX64.EFI" ;;
    esac
    local efi_src="$MOUNT/usr/share/limine/$efi_name"

    if [[ -f "$efi_src" ]]; then
      mkdir -p "$MOUNT/boot/EFI/limine" "$MOUNT/boot/EFI/BOOT"
      cp "$efi_src" "$MOUNT/boot/EFI/limine/limine.efi"
      cp "$efi_src" "$MOUNT/boot/EFI/BOOT/$efi_name"
      # every path limine searches, old + new lookup rules
      cp "$MOUNT/boot/limine/limine.conf" "$MOUNT/boot/limine.conf"
      cp "$MOUNT/boot/limine/limine.conf" "$MOUNT/boot/EFI/limine/limine.conf"

      # verify on-disk BEFORE unmount; silent absence was the old failure mode
      local missing=0 f
      for f in "$MOUNT/boot/EFI/BOOT/$efi_name" \
               "$MOUNT/boot/EFI/limine/limine.efi" \
               "$MOUNT/boot/limine.conf" \
               "$MOUNT/boot/EFI/limine/limine.conf"; do
        if [[ ! -f "$f" ]]; then
          warn "missing on ESP: $f"
          missing=1
        fi
      done
      if (( missing )); then
        ls -laR "$MOUNT/boot" >&2 || true
        FAILED+=("limine-esp-incomplete")
      fi

      if command -v efibootmgr >/dev/null 2>&1; then
        local esp_part_num
        esp_part_num="$(lsblk -no PARTNUM "$BOOT_PART" 2>/dev/null | head -n1)"
        if [[ -n "$esp_part_num" ]]; then
          efibootmgr --create --disk "$DISK" --part "$esp_part_num" \
            --label "Artix Limine" --loader '\EFI\limine\limine.efi' \
            || warn "efibootmgr entry failed — ESP fallback ($efi_name) still covers boot"
        else
          warn "could not determine ESP partition number, skipping efibootmgr"
        fi
      fi
    else
      warn "limine efi binary ($efi_name) not found in target — limine package missing?"
      FAILED+=("limine-efi-binary")
    fi
  else
    chroot_raw limine bios-install "$DISK" || warn "limine bios install failed"
  fi
}

# Create user account with wheel group, set passwords, configure sudo
create_user() {
  info "creating user"

  # Ensure standard groups exist
  chroot_raw groupadd -f wheel || true
  chroot_raw groupadd -f audio || true
  chroot_raw groupadd -f video || true
  chroot_raw groupadd -f storage || true
  chroot_raw groupadd -f network || true
  chroot_raw groupadd -f optical || true

  # Default shell: fish if installed, else bash
  local shell="/usr/bin/fish"
  if [[ ! -x "$MOUNT$shell" ]]; then
    shell="/bin/bash"
  fi

  # Create user with home dir, wheel group, and shell
  chroot_raw useradd -m -G wheel -s "$shell" "$USERNAME" || warn "useradd failed"
  chroot_raw usermod -aG audio,video,storage,network,optical "$USERNAME" || true

  if ! chroot_raw id "$USERNAME" >/dev/null 2>&1; then
    die "user creation failed"
  fi

  # Set user and root passwords (same password)
  printf '%s:%s\n' "$USERNAME" "$USER_PASSWORD" | chroot_raw chpasswd
  printf 'root:%s\n' "$USER_PASSWORD" | chroot_raw chpasswd || true

  # Enable wheel group sudo access
  if grep -q '^# %wheel ALL=(ALL:ALL) ALL' "$MOUNT/etc/sudoers"; then
    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' "$MOUNT/etc/sudoers"
  elif ! grep -q '^%wheel ALL=(ALL:ALL) ALL' "$MOUNT/etc/sudoers"; then
    echo '%wheel ALL=(ALL:ALL) ALL' >> "$MOUNT/etc/sudoers"
  fi

  # Ensure sudoers.d is included
  if ! grep -qE '^[@#]includedir /etc/sudoers.d' "$MOUNT/etc/sudoers"; then
    echo '#includedir /etc/sudoers.d' >> "$MOUNT/etc/sudoers"
  fi

  chroot_raw visudo -c || true
}

# Copy dotfiles from SCRIPT_DIR/home and create default X11/fish/bash configs
copy_dotfiles() {
  info "copying dotfiles"

  # Copy entire home/ directory tree if it exists
  if [[ -d "$SCRIPT_DIR/home" ]]; then
    cp -a "$SCRIPT_DIR/home/." "$MOUNT/home/$USERNAME/"
  else
    warn "$SCRIPT_DIR/home missing, skipping"
  fi

  # Default .xinitrc: start pipewire, wireplumber, then awesome via dbus-launch
  if [[ ! -f "$MOUNT/home/$USERNAME/.xinitrc" ]]; then
    cat > "$MOUNT/home/$USERNAME/.xinitrc" <<'EOF'
#!/bin/sh

if [ -d /etc/X11/xinit/xinitrc.d ]; then
  for f in /etc/X11/xinit/xinitrc.d/*; do
    [ -x "$f" ] && . "$f"
  done
fi

[ -f "$HOME/.Xresources" ] && xrdb -merge "$HOME/.Xresources"

xsetroot -cursor_name left_ptr &
pipewire &
wireplumber &
pipewire-pulse &

if command -v dbus-launch >/dev/null 2>&1; then
  exec dbus-launch --exit-with-session awesome
else
  exec awesome
fi
EOF
    chmod +x "$MOUNT/home/$USERNAME/.xinitrc"
  fi

  # Fish autostart X on tty1
  mkdir -p "$MOUNT/home/$USERNAME/.config/fish/conf.d"
  cat > "$MOUNT/home/$USERNAME/.config/fish/conf.d/99-autostart-x.fish" <<EOF
if status is-interactive; and test -z "\$DISPLAY"; and test (tty) = /dev/tty1
    exec startx /home/$USERNAME/.xinitrc -- vt1
end
EOF

  # Bash profile autostart X on tty1 (fallback)
  if [[ ! -f "$MOUNT/home/$USERNAME/.bash_profile" ]]; then
    cat > "$MOUNT/home/$USERNAME/.bash_profile" <<'EOF'
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  exec startx ~/.xinitrc -- vt1
fi
EOF
  fi

  # Fix ownership
  chroot_raw chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"
}

# Set default Xft.dpi (96) — only if dotfiles did not ship one
configure_xresources() {
  info "setting default dpi (96) — override in ~/.Xresources if needed"

  if [[ ! -f "$MOUNT/home/$USERNAME/.Xresources" ]]; then
    cat > "$MOUNT/home/$USERNAME/.Xresources" <<EOF
Xft.dpi: 96
EOF
    info "dpi: 96"
  else
    info ".Xresources shipped with dotfiles, keeping it"
  fi
}

# Add temporary NOPASSWD sudo for wheel group (needed for aura/jaiba builds as user)
add_aura_sudoers() {
  mkdir -p "$MOUNT/etc/sudoers.d"
  echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' > "$MOUNT/etc/sudoers.d/99-aura-temp"
  chmod 440 "$MOUNT/etc/sudoers.d/99-aura-temp"
}

# Remove temporary NOPASSWD sudo rule
remove_aura_sudoers() {
  rm -f "$MOUNT/etc/sudoers.d/99-aura-temp"
}

# Install rustup and set default stable toolchain (needed for jaiba and other Rust builds)
setup_rustup() {
  info "setting up rustup"

  # Install rustup if not present
  if ! chroot_raw rustup --version >/dev/null 2>&1; then
    chroot_exec "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y" || {
      warn "rustup install failed"
      FAILED+=("rustup: install failed")
      return 1
    }
  fi

  # Set default stable toolchain for build user
  chroot_exec "sudo -u $USERNAME bash -lc 'rustup default stable'" || {
    warn "rustup default stable failed"
    FAILED+=("rustup: default stable failed")
    return 1
  }
}

# Build aura (AUR helper) from the AUR using makepkg + pacman -U
build_aura() {
  info "building aura from AUR"

  # Verify base-devel (makepkg, etc.) is available
  if ! grep -Fxq base-devel "$WORKDIR/pkglist" 2>/dev/null && ! grep -Fxq makepkg "$WORKDIR/pkglist" 2>/dev/null; then
    warn "makepkg not found, skipping aura"
    FAILED+=("aura: makepkg missing")
    return 1
  fi

  # Enable passwordless sudo for build user (makepkg -s installs makedepends)
  add_aura_sudoers

  # Clone aura from the AUR
  chroot_exec "sudo -u $USERNAME bash -lc 'mkdir -p ~/src && [ -d ~/src/aura ] || git clone https://aur.archlinux.org/aura.git ~/src/aura'" || {
    remove_aura_sudoers
    FAILED+=("aura: git clone failed")
    return 1
  }

  # Build with makepkg -s (installs build deps, builds PKGBIN)
  chroot_exec "sudo -u $USERNAME bash -lc 'cd ~/src/aura && makepkg -s --noconfirm'" || {
    remove_aura_sudoers
    FAILED+=("aura: makepkg failed")
    return 1
  }

  # Install the built package with pacman -U (needs root)
  chroot_exec "sudo -u $USERNAME bash -lc 'cd ~/src/aura && sudo pacman -U --noconfirm *.pkg.tar.zst'" || {
    remove_aura_sudoers
    FAILED+=("aura: pacman -U failed")
    return 1
  }

  # Verify installation
  chroot_raw aura --version || {
    remove_aura_sudoers
    FAILED+=("aura: version check failed")
    return 1
  }

  remove_aura_sudoers
}

# Build jaiba (local Rust TUI KeePass manager) from source
build_jaiba() {
  info "building jaiba (local rust tui keepass manager)"

  # Verify rustup is available
  if ! grep -Fxq rustup "$WORKDIR/pkglist" 2>/dev/null; then
    warn "rustup not found, skipping jaiba"
    FAILED+=("jaiba: rustup missing")
    return 1
  fi

  # Verify local source tree exists
  if [[ ! -d "$SCRIPT_DIR/extra/jaiba" || ! -f "$SCRIPT_DIR/extra/jaiba/Cargo.toml" ]]; then
    warn "$SCRIPT_DIR/extra/jaiba missing or incomplete, skipping jaiba"
    FAILED+=("jaiba: source tree missing")
    return 1
  fi

  # Enable passwordless sudo for build user
  add_aura_sudoers

  # Copy source to user's src directory
  local src="$MOUNT/home/$USERNAME/src/jaiba"
  rm -rf "$src"
  cp -a "$SCRIPT_DIR/extra/jaiba" "$src"
  chroot_raw chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/src"

  # Build jaiba in release mode with locked dependencies
  chroot_exec "sudo -u $USERNAME bash -lc 'cd ~/src/jaiba && PATH=\"\$HOME/.cargo/bin:\$PATH\" cargo build --release --locked'" || {
    remove_aura_sudoers
    FAILED+=("jaiba: cargo build failed")
    return 1
  }

  # Verify binary exists and install to /usr/local/bin
  local jaiba_bin="/home/$USERNAME/src/jaiba/target/release/jaiba"
  if [[ ! -f "$MOUNT$jaiba_bin" ]]; then
    remove_aura_sudoers
    FAILED+=("jaiba: binary missing after build")
    return 1
  fi

  install -Dm755 "$MOUNT$jaiba_bin" "$MOUNT/usr/local/bin/jaiba"

  # Ship themes + sample config so the TUI is usable out of the box
  mkdir -p "$MOUNT/home/$USERNAME/.config/rama/themes"
  if [[ -d "$src/themes" ]]; then
    cp -a "$src/themes/." "$MOUNT/home/$USERNAME/.config/rama/themes/"
  fi
  if [[ -f "$src/jaiba_config.toml.sample" ]]; then
    cp -a "$src/jaiba_config.toml.sample" "$MOUNT/home/$USERNAME/.config/rama/jaiba_config.toml"
  fi
  chroot_raw chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.config/rama"

  remove_aura_sudoers
  chroot_raw jaiba --version || true
}

aur_try() {
  local pkg
  for pkg in "$@"; do
    if chroot_exec "sudo -u $USERNAME env CARGO_BUILD_JOBS=$AUR_JOBS MAKEFLAGS='-j$AUR_JOBS' bash -lc 'aura -A --noconfirm $pkg'"; then
      return 0
    fi
  done
  return 1
}

install_aur_packages() {
  info "installing aur packages (batched)"

  if ! chroot_raw aura --version >/dev/null 2>&1; then
    warn "aura unavailable, skipping aur packages"
    FAILED+=("aur: aura unavailable")
    return 0
  fi

  if ! chroot_raw pacman -Q awesome >/dev/null 2>&1; then
    aur_try awesome || FAILED+=("aur: awesome")
  fi

  # first-choice variant per app; ONE aura transaction for all of them
  local want=(
    gram-bin obsidian-bin betterbird-bin librewolf-bin opentubex-git greenclip
    bibata-cursor-theme-bin qogir-icon-theme betterlockscreen mpdris2
    ttf-harmonyos-sans ttf-jetbrains-mono-nerd ttf-times-new-roman
    ttf-arial-rounded-mt onlyoffice anki-bin bun-bin
  )

  local todo=() p
  for p in "${want[@]}"; do
    chroot_raw pacman -Q "$p" >/dev/null 2>&1 || todo+=("$p")
  done

  if ((${#todo[@]})); then
    info "aura batch (${#todo[@]} pkgs): ${todo[*]}"
    chroot_exec "sudo -u $USERNAME env CARGO_BUILD_JOBS=$AUR_JOBS MAKEFLAGS='-j$AUR_JOBS' bash -lc 'aura -A --noconfirm ${todo[*]}'" \
      || warn "aura batch reported failures — resolving misses below"
  fi

  # only what didn't land gets its variant chain, one pkg at a time
  for p in "${want[@]}"; do
    chroot_raw pacman -Q "$p" >/dev/null 2>&1 && continue
    case "$p" in
      gram-bin)          aur_try gram-bin gram-git gram-editor-bin gram-editor-git gram-editor gram || FAILED+=("aur: gram") ;;
      obsidian-bin)      aur_try obsidian-bin obsidian obsidian-appimage || FAILED+=("aur: obsidian") ;;
      betterbird-bin)    aur_try betterbird-bin betterbird betterbird-beta-bin || FAILED+=("aur: betterbird") ;;
      librewolf-bin)     aur_try librewolf-bin librewolf librewolf-appimage || FAILED+=("aur: librewolf") ;;
      opentubex-git)     aur_try opentubex-git opentubex-bin opentubex || FAILED+=("aur: opentubex") ;;
      greenclip)         aur_try greenclip || FAILED+=("aur: greenclip") ;;
      bibata-cursor-theme-bin) aur_try bibata-cursor-theme-bin || FAILED+=("aur: bibata-cursor-theme") ;;
      qogir-icon-theme)  aur_try qogir-icon-theme || FAILED+=("aur: qogir-icon-theme") ;;
      betterlockscreen)  aur_try betterlockscreen betterlockscreen-git || FAILED+=("aur: betterlockscreen") ;;
      mpdris2)           aur_try mpdris2 || FAILED+=("aur: mpdris2") ;;
      ttf-harmonyos-sans) aur_try ttf-harmonyos-sans || FAILED+=("aur: ttf-harmonyos-sans") ;;
      ttf-jetbrains-mono-nerd) aur_try ttf-jetbrains-mono-nerd || FAILED+=("aur: ttf-jetbrains-mono-nerd") ;;
      ttf-times-new-roman) aur_try ttf-times-new-roman || FAILED+=("aur: ttf-times-new-roman") ;;
      ttf-arial-rounded-mt) aur_try ttf-arial-rounded-mt || FAILED+=("aur: ttf-arial-rounded-mt") ;;
      onlyoffice)        aur_try onlyoffice || FAILED+=("aur: onlyoffice") ;;
      anki-bin)          if grep -Fxq anki "$WORKDIR/pkglist" 2>/dev/null; then
                           install_pkgs anki || aur_try anki-bin || FAILED+=("anki")
                         else
                           aur_try anki-bin || FAILED+=("aur: anki")
                         fi ;;
      bun-bin)           aur_try bun-bin bun || FAILED+=("aur: bun") ;;
    esac
  done
}

# Final DNS configuration: lock resolv.conf to localhost (dnsmasq/dnscrypt-proxy)
configure_dns_final() {
  info "locking localhost dns"

  # Point to local dnsmasq (which forwards to dnscrypt-proxy)
  cat > "$MOUNT/etc/resolv.conf" <<'EOF'
nameserver 127.0.0.1
nameserver ::1
EOF

  # Make immutable to prevent NetworkManager/other tools from overwriting
  chroot_raw chattr +i /etc/resolv.conf || warn "could not immutable resolv.conf"
}

# Create post-install snapper snapshot for rollback reference
final_snapshot() {
  info "creating post-install snapshot"
  chroot_raw snapper -c root create --description "post-install" || true
}

# Report any failures recorded during installation
report_failures() {
  if ((${#FAILED[@]})); then
    warn "completed with failures:"
    local f
    for f in "${FAILED[@]}"; do
      warn "  - $f"
    done
  else
    info "no recorded failures"
  fi
}

# Cleanup: unmount filesystems, close LUKS, disable swap
cleanup_umount() {
  info "unmounting"
  sync
  if grep -qs "$MOUNT/swap/swapfile" /proc/swaps; then
    swapoff "$MOUNT/swap/swapfile" || true
  fi

  # Reverse-order unmount from /proc/mounts so children go before parents.
  # Per-mount lazy fallback: one busy bind (e.g. /mnt/run) must not abort the
  # whole cascade and strand the LUKS device open.
  local m tries
  for m in $(awk -v mnt="$MOUNT" '$2 == mnt || index($2, mnt "/") == 1 {print $2}' /proc/mounts | sort -r); do
    for tries in 1 2; do
      umount "$m" 2>/dev/null && break
      [[ "$tries" -eq 2 ]] && umount -l "$m" 2>/dev/null
    done
  done
  umount "$MOUNT" 2>/dev/null || umount -l "$MOUNT" 2>/dev/null || true

  tries=0
  until cryptsetup close cryptroot 2>/dev/null || [[ "$tries" -ge 3 ]]; do
    tries=$((tries + 1))
    sleep 1
  done
  cryptsetup close cryptroot 2>/dev/null || warn "cryptroot still open — reboot live to clear"
  CLEANED_UP=1
}

# EXIT trap: run cleanup on failure (non-zero exit) if not already cleaned up
cleanup_on_exit() {
  local rc=$?
  if [[ "$rc" -ne 0 && "$CLEANED_UP" -eq 0 && -d "$MOUNT" ]]; then
    warn "install failed (exit $rc) — unmounting before reboot"
    CLEANED_UP=1
    cleanup_umount || true
  fi
}

# Main installation orchestration function
main() {
  require_root
  ensure_live_packages
  check_internet
  rank_mirrors
  detect_hardware
  ask_user
  select_disk
  confirm_format

  check_disk_space
  check_existing_luks

  partition_disk
  setup_filesystems
  setup_swapfile

  strap_base
  generate_fstab
  prepare_chroot
  init_pacman_keys
  configure_repos
  refresh_pkglist

  install_official_packages
  cleanup_pacman_cache

  configure_locale_hostname
  configure_fonts
  configure_mkinitcpio
  configure_snapper
  configure_network
  configure_ntp
  enable_services
  install_ssh
  configure_firewall
  verify_timesync
  configure_bootloader
  create_limine_hook

  create_user
  copy_dotfiles
  configure_xresources

  setup_rustup || true
  build_aura || true
  build_jaiba || true
  install_aur_packages || true
  remove_aura_sudoers
  cleanup_aur_builds

  system_update
  configure_dns_final
  final_snapshot
  report_failures
  cleanup_umount

  info "done. reboot."
}

main "$@"
