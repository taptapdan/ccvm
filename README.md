# Isolated Claude Code in a VM — Intel macOS

Runs Claude Code inside a disposable Linux VM. Your Mac's files, credentials,
and system are never reachable from inside. Inside the VM, Claude has full
freedom (Docker, Node, Python, package installs, container builds). The VM wall
is the security boundary. Outbound network is default-deny, enforced by a proxy
on your Mac that the VM cannot tamper with.

---

## Architecture

```
Your Mac (admin account)
├── Lima            — manages the VM, nothing else
├── Squid           — network enforcer (filtering proxy), on the Mac
├── pf              — packet filter, raw-IP egress backstop
├── macOS keychain  — stores all credential values, encrypted at rest
│
└── Linux VM (x86_64 Ubuntu 24.04, native on Intel)
    ├── claude user (non-root, no sudo) — runs Claude Code
    │   ├── Claude Code
    │   ├── Docker + Compose
    │   ├── Node.js LTS
    │   ├── Python 3 + pip + venv
    │   └── gcloud (optional)
    └── No proxy, no firewall, no persisted credentials inside the VM
```

---

## Files

| File | Purpose |
|------|---------|
| `setup_claude_code` | Builds/refreshes everything. Run from your admin account, **no sudo**. Idempotent. |
| `claude-vm.conf` | The one file you edit: resources, allowlist, ports, shared folder, tools. |
| `vm-provision.sh` | Runs inside the VM (invoked by the setup script). Don't run by hand. |
| `manage_credentials` | Add/remove/list credentials in the macOS keychain. |
| `CREDENTIALS.md` | Plain-English credential how-to. |
| `README.md` | This file. |

---

## First run

```bash
chmod +x setup_claude_code vm-provision.sh manage_credentials
./setup_claude_code
```

Installs Homebrew (if needed), Lima, and Squid; downloads Ubuntu; builds the
VM; installs the stack; configures the Mac-side proxy. First build takes a few
minutes. Run as your normal admin user — **not** with sudo.

Then open a **new terminal** (to pick up the `ccvm` alias) and:

```bash
ccvm           # enter the VM as the non-root 'claude' user
claude         # start Claude Code; first time only, run /login once
```

---

## Daily workflow

```bash
ccvm           # enters the VM, injecting any env/file credentials for the session
claude         # full Claude Code terminal UI, exactly as in Anthropic's demo
```

`ccvm` starts the VM if needed, pulls credentials from the keychain, injects
env-type credentials and mounts the GCP key file (if configured) for the
session, and drops you in as `claude`.

---

## Changing configuration

Edit `claude-vm.conf`, then re-run `./setup_claude_code`.

- Allowlist, forwarded ports, shared folder, installed tools → applied live.
- CPU / memory / disk → `limactl stop claude-dev` first, then re-run.

---

## Network security

Two layers, both enforced on your Mac where VM root can't touch them.

**Layer 1 — Squid proxy (primary, domain-aware enforcer).**
The VM's tools are configured to route all traffic through Squid on your Mac
(`host.lima.internal:3128`). Squid allows only the domains in `claude-vm.conf`
and refuses everything else. Effective against any tool that honors the proxy
env (Claude Code, npm, pip, git, curl, docker pull).

**Layer 2 — pf firewall (backstop against raw-IP bypass).**
`socket_vmnet` puts the VM on a kernel-visible bridge interface. pf rules on
that bridge drop traffic from the VM's subnet (`192.168.105.0/24`) to anywhere
except the Squid proxy port and Lima's DNS resolver. Even a process that
deliberately bypasses the proxy env and connects to a raw IP is dropped here,
before NAT, before the packet can leave your Mac.

**Why socket_vmnet matters:** Lima's default `usernet` mode routes VM traffic
through Lima's own userspace process, so pf never sees the VM's source IPs —
the backstop can't work. `socket_vmnet` creates a real kernel bridge; pf sees
the VM's IPs and can filter on them. The Lima sudoers entry lets Lima manage
this interface without prompting for a password on every VM start.

**Your Mac's traffic is never affected.** The pf rules match only on source
addresses in `192.168.105.0/24` (the VM's subnet). Your Mac's traffic has a
different source address and is never touched by these rules.

The allowlist convention: `.example.com` matches the domain and all subdomains;
`host.example.com` matches that exact host. The `PROTECTED_DOMAINS` block
(Anthropic API/auth/telemetry) must stay or Claude Code won't start.

Watch what the VM is reaching (including blocked attempts):

```bash
tail -f ~/.claude-vm/squid-access.log
```

To remove the pf rules completely (e.g. if you no longer use the VM):

```bash
sudo pfctl -a cc-vm -F all
sudo sed -i '' '/cc-vm/d' /etc/pf.conf
sudo launchctl unload /Library/LaunchDaemons/com.claudevm.pf.plist
sudo rm /Library/LaunchDaemons/com.claudevm.pf.plist
```

---

## Credentials (summary — full detail in CREDENTIALS.md)

Values live only in the macOS keychain. Two delivery mechanisms:

- **env** — injected as an environment variable into the `ccvm` session, in
  memory only, gone on exit. Default and recommended.
- **proxy** — value stays on the Mac; Squid injects it into HTTPS requests to a
  named domain (requires scoped TLS interception — see CREDENTIALS.md).

```bash
./manage_credentials add github          # env, GITHUB_TOKEN (built-in default)
./manage_credentials add gcp             # env, mounts your JSON key for the session
./manage_credentials add stripe --type=proxy
./manage_credentials list
./manage_credentials remove github
```

For Anthropic on a Pro/Max plan, just run `/login` once inside Claude Code — no
credential entry needed.

---

## Shared folder

One directory on your Mac (`SHARED_DIR` in the config), mounted into the VM at
`/home/claude/shared`, writable. Your way to move files in and out. Everything
else — projects, credentials, config — stays inside the VM. Leave it empty for
maximum isolation. Anything Claude can do in the VM, it can do to that folder,
so keep it scoped to the current project rather than a broad code directory.

---

## Port forwarding

Each port in `claude-vm.conf` is labelled `network` or `local`:

```bash
FORWARD_PORTS=(
  "8888:network"   # reachable from other devices on your WiFi
  "3000:network"
  "3306:local"     # MySQL — your Mac's localhost only
)
```

- `network` → binds `0.0.0.0` on your Mac; reach it from another workstation at
  `http://<your-mac-ip>:8888` or `http://<your-mac-name>.local:8888`.
- `local` → binds `127.0.0.1`; your Mac only.

No VPN or tunneling needed on the other device. Two gotchas: services inside the
VM must bind to `0.0.0.0` (not `127.0.0.1`) to be reachable; and your Mac's WiFi
IP can change (DHCP) — use the `.local` hostname or set a static IP for a stable
address.

---

## Security guarantees and honest limits

**Absolute (does not depend on anything inside the VM behaving):**
- The VM's filesystem is fully isolated from your Mac. Claude cannot see your
  home directory, SSH keys, browser, or any Mac files.
- Credential values are never written to disk by these scripts; they live in the
  keychain. env credentials exist only in session memory; the GCP key file is
  recreated each session and is not part of the VM image.

**Strong (covers the realistic threat):**
- Network enforcement is on the Mac, outside VM root's reach. It fully stops
  accidental or prompt-injected egress to unlisted domains.

**Conscious trade-offs:**
- `network`-labelled ports are reachable by any device on your WiFi. Fine for
  local dev services with no real data; be aware on shared/public networks.
- Claude Code auto-updates from Anthropic's servers (on the allowlist). You're
  trusting Anthropic's release process on an ongoing basis.
- Docker inside the VM is root-equivalent *within the VM*. A deliberately
  hostile process could manipulate in-VM state, but the Mac-side enforcement
  (Squid, pf) is unaffected.
- Proxy-injected credentials require decrypting traffic to those specific
  domains on your Mac (scoped TLS interception). env injection avoids this.

**Trust root:** Lima, Squid, and pf run under your Mac admin account. This is
unavoidable and the same trust assumption as any software you run.

---

## First-run verification (important)

These scripts are syntax-checked, but the Mac↔VM networking is the part that
varies by machine and that I could not test for your exact setup. On first run,
verify enforcement from inside the VM:

```bash
ccvm
curl -sS -o /dev/null -w "%{http_code}\n" https://api.anthropic.com   # expect a 2xx/4xx (reached)
curl -sS -o /dev/null -w "%{http_code}\n" https://example.com         # expect failure/blocked
```

If an install is blocked, check `~/.claude-vm/squid-access.log`, add the domain
to `claude-vm.conf`, and re-run `./setup_claude_code`.

Likely first-run adjustments:
- If the VM won't boot, change `vmType: "vz"` to `"qemu"` in
  `~/.claude-vm/claude-dev.lima.yaml` (or ask and I'll parameterize it).
- The `pf` raw-IP backstop is the piece most likely to need per-machine tuning;
  Squid is the primary enforcer and works regardless.

---

## Requirements

- Intel Mac, macOS 13.0 (Ventura) or later
- Paid Anthropic plan (Pro / Max / Team / Enterprise / Console)
- ~10 GB free disk
- Homebrew (the setup script installs it if missing; `socket_vmnet`, `lima`,
  and `squid` are installed automatically from Homebrew)

## Useful commands

```bash
limactl list                  # VM status
limactl stop claude-dev       # shut down
limactl start claude-dev      # bring back
limactl delete claude-dev     # destroy (rebuild with ./setup_claude_code)
tail -f ~/.claude-vm/squid-access.log   # live network log
```
