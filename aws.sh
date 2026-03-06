#!/usr/bin/env bash
set -euo pipefail

# ============ Config (override via env) ============
SWAP_SIZE_GB="${SWAP_SIZE_GB:-2}"
NODE_MAX_OLD_SPACE_MB="${NODE_MAX_OLD_SPACE_MB:-256}"

# trimming defaults
CONFIRM_SNAP_PURGE="${CONFIRM_SNAP_PURGE:-1}"   # default: purge snapd
PURGE_MULTIPATH="${PURGE_MULTIPATH:-1}"
DISABLE_FWUPD="${DISABLE_FWUPD:-1}"
DISABLE_APPORT="${DISABLE_APPORT:-1}"
DISABLE_MOTD_NEWS="${DISABLE_MOTD_NEWS:-1}"
TUNE_JOURNALD="${TUNE_JOURNALD:-1}"
JOURNALD_SYSTEM_MAX_USE="${JOURNALD_SYSTEM_MAX_USE:-50M}"
JOURNALD_RUNTIME_MAX_USE="${JOURNALD_RUNTIME_MAX_USE:-30M}"

# advanced tuning toggles
TUNE_SSH="${TUNE_SSH:-1}"
TUNE_DNS="${TUNE_DNS:-1}"
TUNE_TMUX="${TUNE_TMUX:-1}"
TUNE_LIMITS="${TUNE_LIMITS:-1}"

# tmux tuning defaults
TMUX_HISTORY_LIMIT="${TMUX_HISTORY_LIMIT:-200}" # reduce scrollback memory

SYSCTL_CONF="/etc/sysctl.d/99-vps-tuning.conf"
SWAPFILE="/swapfile"

log()  { echo -e "\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
err()  { echo -e "\033[1;31m[✗] $*\033[0m" >&2; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

# ============ Preflight ============
if ! need_cmd sudo; then
  err "sudo not found. Please install sudo or run as root."
  exit 1
fi

log "Updating apt & installing base packages (curl, build-essential, htop, glances, earlyoom)..."
sudo apt update -y
sudo apt install -y curl build-essential htop glances earlyoom

# ============ STEP 1: Swap ============
log "STEP 1: Ensuring swap exists and is enabled..."
if swapon --show | awk '{print $1}' | grep -qx "$SWAPFILE"; then
  log "Swapfile already enabled: $SWAPFILE"
else
  if [[ -f "$SWAPFILE" ]]; then
    warn "$SWAPFILE exists but not enabled. Will try to enable it."
  else
    log "Creating ${SWAP_SIZE_GB}G swapfile at $SWAPFILE ..."
    if need_cmd fallocate; then
      sudo fallocate -l "${SWAP_SIZE_GB}G" "$SWAPFILE" || true
    fi
    if [[ ! -s "$SWAPFILE" ]]; then
      warn "fallocate failed or produced empty file; using dd (slower)..."
      sudo dd if=/dev/zero of="$SWAPFILE" bs=1M count=$((SWAP_SIZE_GB * 1024)) status=progress
    fi
    sudo chmod 600 "$SWAPFILE"
    sudo mkswap "$SWAPFILE"
  fi

  sudo swapon "$SWAPFILE"
  log "Swap enabled."
fi

if ! grep -qE "^\s*$SWAPFILE\s+none\s+swap\s" /etc/fstab; then
  log "Persisting swap in /etc/fstab ..."
  echo "$SWAPFILE none swap sw 0 0" | sudo tee -a /etc/fstab >/dev/null
else
  log "Swap persistence already present in /etc/fstab"
fi

# ============ STEP 2: Sysctl tuning (low-latency + websocket stability) ============
log "STEP 2: Writing sysctl tuning to $SYSCTL_CONF ..."

# Choose congestion control (BBR preferred)
CC="cubic"
if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw "bbr"; then
  CC="bbr"
fi

sudo tee "$SYSCTL_CONF" >/dev/null <<EOF
# Tunings for small VPS stability + low-latency networking (websocket/market data)

# ---- memory / swap ----
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.overcommit_memory=1

# ---- queueing / backlog ----
net.core.netdev_max_backlog=32768
net.core.somaxconn=4096

# ---- socket buffers (moderate; safe for 1GB VPS) ----
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216

# ---- latency & path robustness ----
net.ipv4.tcp_low_latency=1
net.ipv4.tcp_mtu_probing=1

# ---- keepalives: keep NAT/WebSocket alive & detect dead peers faster ----
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=6

# ---- TIME_WAIT handling for client reconnect patterns ----
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_tw_reuse=1

# ---- ephemeral ports (avoid port exhaustion on bursts/reconnects) ----
net.ipv4.ip_local_port_range=10240 65535

# ---- modern congestion control + fq pacing (good for latency) ----
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=${CC}
EOF

sudo sysctl --system >/dev/null
log "Sysctl applied. Congestion control: ${CC}"

# ============ STEP 2.5: Trim services/packages ============
log "STEP 2.5: Trimming unnecessary services/packages..."

if [[ "$PURGE_MULTIPATH" == "1" ]]; then
  log "Disabling & removing multipath..."
  sudo systemctl stop multipathd >/dev/null 2>&1 || true
  sudo systemctl disable multipathd >/dev/null 2>&1 || true
  sudo apt purge -y multipath-tools >/dev/null 2>&1 || true
fi

if [[ "$DISABLE_FWUPD" == "1" ]]; then
  log "Disabling fwupd..."
  sudo systemctl stop fwupd >/dev/null 2>&1 || true
  sudo systemctl disable fwupd >/dev/null 2>&1 || true
  sudo systemctl mask fwupd >/dev/null 2>&1 || true
fi

if [[ "$DISABLE_APPORT" == "1" ]]; then
  log "Disabling apport..."
  sudo systemctl stop apport >/dev/null 2>&1 || true
  sudo systemctl disable apport >/dev/null 2>&1 || true
fi

if [[ "$DISABLE_MOTD_NEWS" == "1" ]]; then
  if [[ -f /etc/update-motd.d/50-motd-news ]]; then
    log "Disabling motd-news..."
    sudo chmod -x /etc/update-motd.d/50-motd-news || true
  fi
fi

if [[ "$TUNE_JOURNALD" == "1" ]]; then
  log "Capping journald usage..."
  sudo mkdir -p /etc/systemd/journald.conf.d
  sudo tee /etc/systemd/journald.conf.d/99-vps-cap.conf >/dev/null <<EOF
[Journal]
SystemMaxUse=${JOURNALD_SYSTEM_MAX_USE}
RuntimeMaxUse=${JOURNALD_RUNTIME_MAX_USE}
EOF
  sudo systemctl restart systemd-journald || true
fi

if [[ "$CONFIRM_SNAP_PURGE" == "1" ]]; then
  log "Purging snapd (default)..."
  if command -v snap >/dev/null 2>&1; then
    if snap list 2>/dev/null | awk '{print $1}' | grep -qx "amazon-ssm-agent"; then
      warn "Detected snap 'amazon-ssm-agent'. Purging snapd will remove it."
    fi
  fi
  sudo systemctl stop snapd.service snapd.socket snapd.seeded.service >/dev/null 2>&1 || true
  sudo systemctl disable snapd.service snapd.socket snapd.seeded.service >/dev/null 2>&1 || true
  sudo systemctl mask snapd.service snapd.socket snapd.seeded.service >/dev/null 2>&1 || true
  sudo systemctl stop snapd.refresh.timer >/dev/null 2>&1 || true
  sudo systemctl disable snapd.refresh.timer >/dev/null 2>&1 || true
  sudo systemctl mask snapd.refresh.timer >/dev/null 2>&1 || true

  sudo apt purge -y snapd || true
  sudo rm -rf /snap /var/snap /var/lib/snapd ~/snap || true
  log "snapd purged."
fi

# ============ STEP 3: Protect SSH from OOM killer ============
log "STEP 3: Protecting SSH service from OOM killer..."
SSH_UNIT=""
if systemctl list-unit-files | awk '{print $1}' | grep -qx "ssh.service"; then
  SSH_UNIT="ssh.service"
elif systemctl list-unit-files | awk '{print $1}' | grep -qx "sshd.service"; then
  SSH_UNIT="sshd.service"
else
  warn "Neither ssh.service nor sshd.service found. Skipping SSH OOM protection."
fi

if [[ -n "$SSH_UNIT" ]]; then
  OVERRIDE_DIR="/etc/systemd/system/${SSH_UNIT}.d"
  sudo mkdir -p "$OVERRIDE_DIR"
  sudo tee "${OVERRIDE_DIR}/override.conf" >/dev/null <<'EOF'
[Service]
OOMScoreAdjust=-1000
EOF
  sudo systemctl daemon-reload
  sudo systemctl restart "$SSH_UNIT" >/dev/null 2>&1 || true
  log "Applied OOMScoreAdjust=-1000 to $SSH_UNIT"
fi

# ============ STEP 3.5: SSH speed tuning ============
if [[ "$TUNE_SSH" == "1" ]]; then
  log "STEP 3.5: Tuning SSH for faster logins..."
  SSHD_CFG="/etc/ssh/sshd_config"
  TS="$(date +%Y%m%d-%H%M%S)"
  if [[ -f "$SSHD_CFG" ]]; then
    sudo cp -a "$SSHD_CFG" "${SSHD_CFG}.bak.${TS}"

    # UseDNS no
    if grep -qE '^\s*UseDNS\s+' "$SSHD_CFG"; then
      sudo sed -i 's/^\s*UseDNS\s\+.*/UseDNS no/' "$SSHD_CFG"
    else
      echo "UseDNS no" | sudo tee -a "$SSHD_CFG" >/dev/null
    fi

    # GSSAPIAuthentication no
    if grep -qE '^\s*GSSAPIAuthentication\s+' "$SSHD_CFG"; then
      sudo sed -i 's/^\s*GSSAPIAuthentication\s\+.*/GSSAPIAuthentication no/' "$SSHD_CFG"
    else
      echo "GSSAPIAuthentication no" | sudo tee -a "$SSHD_CFG" >/dev/null
    fi

    sudo systemctl restart ssh >/dev/null 2>&1 || sudo systemctl restart sshd >/dev/null 2>&1 || true
    log "SSHD tuned. Backup: ${SSHD_CFG}.bak.${TS}"
  else
    warn "sshd_config not found; skipping SSH tuning."
  fi
fi

# ============ STEP 4: Limit Node memory ============
log "STEP 4: Setting NODE_OPTIONS=--max-old-space-size=${NODE_MAX_OLD_SPACE_MB} ..."
append_once() {
  local file="$1"
  local line="$2"
  [[ -f "$file" ]] || return 0
  if ! grep -qF "$line" "$file"; then
    echo "" >> "$file"
    echo "# Added by vps_tune.sh" >> "$file"
    echo "$line" >> "$file"
    log "Updated $file"
  fi
}

NODE_LINE="export NODE_OPTIONS=\"--max-old-space-size=${NODE_MAX_OLD_SPACE_MB}\""
USER_HOME="${HOME:-/root}"
append_once "${USER_HOME}/.bashrc" "$NODE_LINE"
append_once "${USER_HOME}/.zshrc"  "$NODE_LINE"

GLOBAL_NODE_CONF="/etc/profile.d/node_options.sh"
if ! sudo grep -qF "$NODE_LINE" "$GLOBAL_NODE_CONF" 2>/dev/null; then
  sudo tee "$GLOBAL_NODE_CONF" >/dev/null <<EOF
# Added by vps_tune.sh
$NODE_LINE
EOF
  log "Updated $GLOBAL_NODE_CONF"
fi

# ============ STEP 4.5: DNS tuning ============
if [[ "$TUNE_DNS" == "1" ]]; then
  log "STEP 4.5: Tuning DNS (systemd-resolved cache)..."
  if systemctl is-active systemd-resolved >/dev/null 2>&1; then
    sudo mkdir -p /etc/systemd/resolved.conf.d
    sudo tee /etc/systemd/resolved.conf.d/99-vps.conf >/dev/null <<'EOF'
[Resolve]
DNSStubListener=yes
Cache=yes
EOF
    sudo systemctl restart systemd-resolved || true
    log "systemd-resolved tuned."
  else
    warn "systemd-resolved not active; skipping DNS tuning."
  fi
fi

# ============ STEP 4.6: Open file limits (important for many sockets) ============
if [[ "$TUNE_LIMITS" == "1" ]]; then
  log "STEP 4.6: Setting higher open file limits (nofile)..."
  sudo tee /etc/security/limits.d/99-nofile.conf >/dev/null <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

  # systemd default limits
  sudo mkdir -p /etc/systemd/system.conf.d
  sudo tee /etc/systemd/system.conf.d/99-nofile.conf >/dev/null <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF

  warn "nofile limits set. A reboot (or at least re-login) is required for all services to fully pick it up."
fi

# ============ STEP 5: tmux memory tuning ============
if [[ "$TUNE_TMUX" == "1" ]]; then
  log "STEP 5: Tuning tmux to reduce memory (history-limit=${TMUX_HISTORY_LIMIT})..."
  TMUX_CONF="${USER_HOME}/.tmux.conf"
  [[ -f "$TMUX_CONF" ]] || touch "$TMUX_CONF"
  if ! grep -qE '^\s*set\s+-g\s+history-limit\s+' "$TMUX_CONF"; then
    {
      echo ""
      echo "# Added by vps_tune.sh - reduce scrollback to save RAM"
      echo "set -g history-limit ${TMUX_HISTORY_LIMIT}"
    } >> "$TMUX_CONF"
    log "Appended history-limit to $TMUX_CONF"
  else
    log "$TMUX_CONF already sets history-limit; leaving as-is."
  fi
  warn "To apply tmux change: tmux kill-server (will close sessions)."
  warn "Or clear buffers in-session: Ctrl+b : then 'clear-history'"
fi

# ============ STEP 6: earlyoom ============
log "STEP 6: Enabling earlyoom..."
sudo systemctl enable --now earlyoom >/dev/null
log "earlyoom enabled."

# ============ STEP 7: Cleanup ============
log "STEP 7: apt cleanup..."
sudo apt autoremove -y >/dev/null 2>&1 || true
sudo apt clean || true
log "Cleanup complete."

# ============ Summary ============
log "DONE. Quick status:"
echo "---- free -h ----"
free -h || true
echo
echo "---- swapon --show ----"
swapon --show || true
echo
echo "---- sysctl (selected) ----"
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.tcp_keepalive_time net.ipv4.ip_local_port_range || true
echo
warn "Reboot recommended after package/service removals & limits changes."
warn "Code tip: For lowest latency in WebSocket/TCP clients, enable TCP_NODELAY in your app where possible."
