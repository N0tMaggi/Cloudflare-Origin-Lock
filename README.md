# Cloudflare Origin Lock (nftables)

`cloudflare-origin-lock.sh` is a self-contained hardening script for Debian/Ubuntu servers that only allows HTTP(S) traffic from Cloudflare's official IP ranges. It fetches Cloudflare's latest CIDR lists, writes nftables sets, and keeps the configuration transactional so you can safely apply, update, or roll back with a single command.

---

## Highlights

- Enforces that only Cloudflare edges can reach ports 80 and 443 while preserving SSH access.
- Performs transactional applies/updates with automatic rollback on failure.
- Detects your SSH listening port so you can't accidentally lock yourself out.
- Stores state under `/var/lib/cloudflare-origin-lock` and keeps working backups for reversions.
- Supports unattended refreshes (cron/systemd timer) via the `update` action.

---

## Requirements

- Debian or Ubuntu system using `nftables`.
- Root privileges (`sudo` or direct root shell).
- System utilities: `curl`, `nft`, `systemctl`, `flock`, `awk`, `sed`, `wc`, `grep`.
- Outbound HTTPS access to `www.cloudflare.com` to download the IP lists.

---

## Files and Directories Touched

| Path | Purpose |
| ---- | ------- |
| `/etc/nftables.d/cloudflare-sets.nft` | Generated `cf_origin_lock` table and sets with Cloudflare IPs. |
| `/etc/nftables.conf` | Appends `include "/etc/nftables.d/*.nft"` if it is missing. |
| `/etc/nftables.d/cloudflare-sets.nft.prev.cf-lock` | Backup of the previous sets file for rollback. |
| `/etc/nftables.conf.prev.cf-lock` | Backup of the main nftables config before the include line is added. |
| `/var/lib/cloudflare-origin-lock/installed` | Timestamp marker indicating the script is applied. |
| `/var/lock/cloudflare-origin-lock.lck` | File lock to prevent concurrent runs. |

All backups are only created or restored when needed. Removing the script will not delete these files automatically, so you retain full control.

---

## Usage

```bash
sudo ./cloudflare-origin-lock.sh <command>
```

Supported commands:

### `apply`

Bootstraps the configuration from scratch:

1. Downloads the current IPv4 and IPv6 ranges published by Cloudflare.
2. Builds an nftables table `inet cf_origin_lock` with two sets: `cf4` and `cf6`.
3. Creates an input chain that:
   - accepts established/related traffic,
   - allows localhost traffic,
   - keeps your SSH port (autodetected, fallback to 22) open,
   - accepts HTTP/S only when the source IP belongs to Cloudflare,
   - drops all other HTTP/S attempts.
4. Ensures `/etc/nftables.conf` includes `/etc/nftables.d/*.nft`.
5. Reloads nftables via `systemctl reload nftables` (falls back to `restart`).
6. Writes an installation marker with the current timestamp.

If nftables fails to reload, the script restores backups and aborts with an error.

### `update`

Re-fetches Cloudflare ranges and swaps them in place. A temporary backup of the existing sets file is kept; if the reload fails, the script rolls back the old rules automatically. Use this regularly (e.g., cron) to track Cloudflare IP updates.

### `revert`

Removes the generated sets file and restores any backup of `/etc/nftables.conf`, then reloads nftables. This returns the firewall to its previous state and removes the installation marker.

### `status`

Shows whether the lock is installed, when it was last applied, and prints the first 100 lines of the live ruleset so you can verify the active chain.

### Interactive Mode

Run the script with no arguments to enter a simple `select` menu (`apply`, `update`, `revert`, `status`, `exit`). The same safeguards apply.

---

## Safety Features

- **Idempotent detection** – rerunning `apply` is safe; if the include line already exists it won't be duplicated.
- **nftables syntax validation** – rules are compiled with `nft -c` before being installed.
- **SSH guardrails** – if your SSH port is 80 or 443, the script aborts to avoid self-lockout.
- **File locking** – `flock` prevents simultaneous executions that could corrupt state.
- **Transactional backups** – previous configuration files are kept until the new rules are successfully loaded.

---

## Customization

- **Allowed application ports**: At the top of the script, `define CF_PORTS = { 80, 443 }`. Modify and rerun `apply` if you expose additional HTTPS-based services on alternative ports.
- **SSH detection**: The script reads `/etc/ssh/sshd_config` for the last declared `Port`. If you manage SSH elsewhere (e.g., via `sshd_config.d`), confirm detection with `./cloudflare-origin-lock.sh status`.
- **State paths**: Adjust `SETS_FILE`, `NFT_MAIN`, or `STATE_DIR` variables in the script if your distribution uses customized locations.

Whenever you edit the script, rerun `apply` so the nftables configuration syncs with your changes.

---

## Automating Updates

Because Cloudflare ranges change periodically, schedule the `update` action. Example systemd timer:

```ini
# /etc/systemd/system/cloudflare-origin-lock-update.service
[Unit]
Description=Refresh Cloudflare origin allow-list

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cloudflare-origin-lock.sh update

# /etc/systemd/system/cloudflare-origin-lock-update.timer
[Unit]
Description=Run Cloudflare origin update daily

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
```

Enable with:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now cloudflare-origin-lock-update.timer
```

---

## Troubleshooting

- **`Missing commands: ...`** – install the listed packages (`apt install curl nftables gawk sed grep coreutils`).
- **`nftables reload failed`** – inspect `journalctl -u nftables` for syntax errors, then fix and rerun `apply`.
- **No traffic reaches your origin** – confirm the Cloudflare proxy is enabled (orange cloud) and `status` shows the `cf_origin_lock` chain.
- **Need to allow additional IPs** – add them manually to `/etc/nftables.d/cloudflare-sets.nft` under the appropriate set and reload nftables, or maintain a companion include file.

If everything appears correct but traffic still fails, run `sudo nft list ruleset | less` to inspect the active policy and confirm the `cf_origin_lock` chain is attached.

---

## Removal

1. Run `sudo ./cloudflare-origin-lock.sh revert`.
2. Delete the generated files if desired:
   ```bash
   sudo rm -f /etc/nftables.d/cloudflare-sets.nft
   sudo rm -f /etc/nftables.conf.prev.cf-lock /etc/nftables.d/cloudflare-sets.nft.prev.cf-lock
   sudo rm -rf /var/lib/cloudflare-origin-lock
   ```
3. Optionally remove the script itself.

---

## License

No explicit license is provided. Treat this script as internal infrastructure code unless you add a license header.
