#!/usr/bin/env bash
# Cloudflare Origin Lock for Debian/Ubuntu (nftables)
# Only allows Cloudflare IPs on ports 80 and 443 (HTTP/HTTPS)
# Actions: apply / update / revert / status
# Strong error handling, transactional apply/update with rollback

set -Eeuo pipefail
shopt -s lastpipe

# ========= CONFIG =========
V4_URL="https://www.cloudflare.com/ips-v4"
V6_URL="https://www.cloudflare.com/ips-v6"

SETS_FILE="/etc/nftables.d/cloudflare-sets.nft"
SETS_FILE_PREV="/etc/nftables.d/cloudflare-sets.nft.prev.cf-lock"
NFT_MAIN="/etc/nftables.conf"
NFT_MAIN_PREV="/etc/nftables.conf.prev.cf-lock"
INCLUDE_LINE='include "/etc/nftables.d/*.nft"'

STATE_DIR="/var/lib/cloudflare-origin-lock"
MARKER="$STATE_DIR/installed"
LOCK_FILE="/var/lock/cloudflare-origin-lock.lck"

SSH_PORT_DEFAULT=22
LOG_PREFIX="[cf-origin-lock]"

mkdir -p "$STATE_DIR"

# ========= LOGGING =========
log()   { printf '%s %s\n' "$LOG_PREFIX" "$*"; }
warn()  { printf '%s [WARN] %s\n' "$LOG_PREFIX" "$*" >&2; }
die()   { printf '%s [ERROR] %s\n' "$LOG_PREFIX" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF' >&2
Cloudflare Origin Lock (nftables)

Usage:
  sudo ./cloudflare-origin-lock.sh <apply|update|revert|status>

Run without arguments to open an interactive menu.

One-line installer (curl):
  curl -fsSL https://raw.githubusercontent.com/N0tMaggi/Cloudflare-Origin-Lock/main/cloudflare-origin-lock.sh | sudo bash -s -- apply

One-line installer (wget):
  wget -qO- https://raw.githubusercontent.com/N0tMaggi/Cloudflare-Origin-Lock/main/cloudflare-origin-lock.sh | sudo bash -s -- apply
EOF
  exit "${1:-1}"
}

# ========= ROOT & DEPENDENCIES =========
require_root() { [[ $EUID -eq 0 ]] || die "Run as root (sudo)."; }
have_cmd()     { command -v "$1" >/dev/null 2>&1; }
ensure_deps() {
  local missing=()
  for c in curl nft systemctl flock awk sed wc grep; do
    have_cmd "$c" || missing+=("$c")
  done
  ((${#missing[@]}==0)) || die "Missing commands: ${missing[*]}"
}

# ========= LOCKING =========
with_lock() {
  exec 200>"$LOCK_FILE"
  flock -n 200 || die "Another instance is running (lock: $LOCK_FILE)."
}

# ========= HELPERS =========
detect_ssh_port() {
  local p
  p=$(awk '/^[Pp]ort[[:space:]]+[0-9]+/ {print $2}' /etc/ssh/sshd_config 2>/dev/null | tail -n1 || true)
  [[ -n "${p:-}" ]] && echo "$p" || echo "$SSH_PORT_DEFAULT"
}

fetch_lists() {
  local tmp="$1"
  curl -fsSL "$V4_URL" -o "$tmp/ips-v4" || die "Failed to fetch IPv4 list."
  curl -fsSL "$V6_URL" -o "$tmp/ips-v6" || die "Failed to fetch IPv6 list."
  [[ $(wc -l < "$tmp/ips-v4") -ge 5 ]] || die "IPv4 list too short (validation failed)."
  [[ $(wc -l < "$tmp/ips-v6") -ge 5 ]] || die "IPv6 list too short (validation failed)."
}

render_sets_file() {
  local tmp="$1" out="$tmp/cloudflare-sets.nft" ssh_port="$2"
  {
    echo 'define CF_PORTS = { 80, 443 }'
    echo ''
    echo 'table inet cf_origin_lock {'
    printf '  set cf4 { type ipv4_addr; flags interval; elements = { '
    awk 'NF{printf "%s, ", $0}' "$tmp/ips-v4" | sed 's/, $//'
    echo ' } }'
    printf '  set cf6 { type ipv6_addr; flags interval; elements = { '
    awk 'NF{printf "%s, ", $0}' "$tmp/ips-v6" | sed 's/, $//'
    echo ' } }'
    echo ''
    echo '  chain input_cf_lock {'
    echo '    type filter hook input priority 0; policy accept;'
    echo '    ct state established,related accept'
    echo '    iif "lo" accept'
    echo "    tcp dport $ssh_port accept"
    echo '    tcp dport $CF_PORTS ip saddr @cf4 accept'
    echo '    tcp dport $CF_PORTS ip6 saddr @cf6 accept'
    echo '    tcp dport $CF_PORTS drop'
    echo '  }'
    echo '}'
  } > "$out"
  nft -c -f "$out" >/dev/null || die "nftables syntax check failed."
  echo "$out"
}

ensure_include_if_missing_txn() {
  # Only touch nftables.conf if needed; keep a transactional backup
  if ! grep -Fq "$INCLUDE_LINE" "$NFT_MAIN"; then
    [[ -f "$NFT_MAIN_PREV" ]] || cp -a "$NFT_MAIN" "$NFT_MAIN_PREV"
    echo "$INCLUDE_LINE" >> "$NFT_MAIN" || die "Failed to append include to $NFT_MAIN"
    echo "include_added"
  else
    echo "include_present"
  fi
}

install_sets_txn() {
  local new_file="$1"
  # Keep previous sets for rollback
  [[ -f "$SETS_FILE" ]] && cp -a "$SETS_FILE" "$SETS_FILE_PREV" || true
  install -m 0644 -D "$new_file" "$SETS_FILE" || die "Failed to install sets file."
  echo "sets_installed"
}

reload_nftables_txn() {
  systemctl reload nftables 2>/dev/null || systemctl restart nftables || return 1
  return 0
}

rollback_apply() {
  local include_state="$1" sets_state="$2"
  warn "Rolling back changes..."

  # Revert sets file
  if [[ "$sets_state" == "sets_installed" ]]; then
    if [[ -f "$SETS_FILE_PREV" ]]; then
      mv -f "$SETS_FILE_PREV" "$SETS_FILE" || warn "Failed to restore previous sets file."
    else
      rm -f "$SETS_FILE" || true
    fi
  fi

  # Revert include edit
  if [[ "$include_state" == "include_added" && -f "$NFT_MAIN_PREV" ]]; then
    mv -f "$NFT_MAIN_PREV" "$NFT_MAIN" || warn "Failed to restore $NFT_MAIN"
  fi

  # Try reloading again to restore original ruleset
  systemctl reload nftables 2>/dev/null || systemctl restart nftables || warn "nftables reload after rollback failed."
}

apply_rules() {
  local tmp include_state sets_state ssh_port new_file
  tmp="$(mktemp -d)" || die "mktemp failed."
  trap 'rm -rf "$tmp"' RETURN

  ssh_port="$(detect_ssh_port)"
  if [[ "$ssh_port" == "80" || "$ssh_port" == "443" ]]; then
    die "Detected SSH port $ssh_port — refusing to continue (would lock you out)."
  fi

  log "Fetching Cloudflare IP lists..."
  fetch_lists "$tmp"

  log "Rendering temporary nftables file..."
  new_file="$(render_sets_file "$tmp" "$ssh_port")"

  log "Ensuring include line in $NFT_MAIN..."
  include_state="$(ensure_include_if_missing_txn)"

  log "Installing sets file..."
  sets_state="$(install_sets_txn "$new_file")"

  log "Reloading nftables..."
  if ! reload_nftables_txn; then
    rollback_apply "$include_state" "$sets_state"
    die "nftables reload failed — transaction rolled back."
  fi

  date -Iseconds > "$MARKER" || warn "Could not write marker file."
  rm -rf "$tmp"
  trap - RETURN
  log "✅ Apply complete — only Cloudflare IPs can access ports 80/443."
}

update_rules() {
  [[ -f "$MARKER" ]] || die "Not installed (no apply marker). Run 'apply' first."

  local tmp new_file ssh_port
  tmp="$(mktemp -d)" || die "mktemp failed."
  trap 'rm -rf "$tmp"' RETURN

  log "Fetching Cloudflare IP lists..."
  fetch_lists "$tmp"

  ssh_port="$(detect_ssh_port)"
  new_file="$(render_sets_file "$tmp" "$ssh_port")"

  # Transaction: keep current sets as prev, write new, reload, else rollback
  [[ -f "$SETS_FILE" ]] && cp -a "$SETS_FILE" "$SETS_FILE_PREV" || true
  install -m 0644 -D "$new_file" "$SETS_FILE" || die "Failed to install new sets file."

  log "Reloading nftables..."
  if ! reload_nftables_txn; then
    warn "Reload failed — restoring previous sets file."
    if [[ -f "$SETS_FILE_PREV" ]]; then
      mv -f "$SETS_FILE_PREV" "$SETS_FILE" || warn "Failed to restore previous sets file."
      reload_nftables_txn || warn "Reload after rollback failed."
    fi
    die "Update failed; previous state restored."
  fi

  rm -f "$SETS_FILE_PREV" || true
  rm -rf "$tmp"
  trap - RETURN
  log "✅ Update complete — Cloudflare IP ranges refreshed."
}

revert_rules() {
  local changed=0

  # Revert sets file
  if [[ -f "$SETS_FILE_PREV" ]]; then
    mv -f "$SETS_FILE_PREV" "$SETS_FILE" && changed=1 || warn "Failed to restore previous sets file."
  else
    if [[ -f "$SETS_FILE" ]]; then
      rm -f "$SETS_FILE" && changed=1 || warn "Failed to remove $SETS_FILE"
    fi
  fi

  # Revert include edit
  if [[ -f "$NFT_MAIN_PREV" ]]; then
    mv -f "$NFT_MAIN_PREV" "$NFT_MAIN" && changed=1 || warn "Failed to restore $NFT_MAIN"
  fi

  rm -f "$MARKER" || true

  if ((changed)); then
    reload_nftables_txn || warn "nftables reload after revert failed."
  fi

  log "✅ Revert complete — firewall restored to previous state."
}

status_short() {
  echo "=== Cloudflare Origin Lock Status ==="
  if [[ -f "$MARKER" ]]; then
    echo "Installed on: $(cat "$MARKER")"
  else
    echo "Not installed (no apply marker)."
  fi
  echo
  echo "nftables ruleset (first 100 lines):"
  nft list ruleset | sed -n '1,100p'
}

interactive_menu() {
  echo "Select action:"
  select opt in "apply" "update" "revert" "status" "exit"; do
    case "$opt" in
      apply)  apply_rules;  break ;;
      update) update_rules; break ;;
      revert) revert_rules; break ;;
      status) status_short; break ;;
      exit)   exit 0 ;;
      *) echo "Invalid option";;
    esac
  done
}

main() {
  require_root
  ensure_deps
  with_lock

  local cmd="${1:-}"
  case "$cmd" in
    apply)  apply_rules ;;
    update) update_rules ;;
    revert) revert_rules ;;
    status) status_short ;;
    "" )    interactive_menu ;;
    -h|--help) usage 0 ;;
    * )     usage 1 ;;
  esac
}

main "$@"
