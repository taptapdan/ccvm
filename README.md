# Isolated Claude Code in a VM — Intel macOS

Runs Claude Code inside a disposable Linux VM. Your Mac's files, credentials,
and system are never reachable from inside. Inside the VM, Claude has full
freedom (Docker, Node, Python, package installs, container builds). The VM wall
is the security boundary. Outbound network is enforced by a Squid proxy on your
Mac that the VM cannot tamper with.

---

## Architecture

```
Your Mac (admin account)
├── Lima            — manages the VM, nothing else
├── Squid           — network enforcer (filtering proxy), on the Mac
├── socket_vmnet    — kernel-visible bridge network for the VM
├── macOS keychain  — stores all credential values, encrypted at rest
│
└── Linux VM (x86_64 Ubuntu 24.04, qemu)
    ├── claude user (non-root) — runs Claude Code
    │   ├── Claude Code        (all permissions enabled, no prompts)
    │   ├── Docker + Compose
    │   ├── Node.js LTS
    │   ├── Python 3 + pip + venv
    │   └── gcloud (optional, set INSTALL_GCLOUD=true)
    └── No proxy or firewall inside the VM — enforcement is Mac-side
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

Installs Homebrew (if needed), Lima, QEMU, Squid, and socket_vmnet; builds the
VM; installs the dev stack; configures the Mac-side proxy. Ubuntu is downloaded
once and cached — rebuilds take about a minute. Run as your normal admin user —
**not** with sudo.

Then open a **new terminal** (to pick up the `ccvm` alias):

```bash
ccvm      # enter the VM as the claude user
claude    # start Claude Code
```

**First-time authentication:** Claude Code will show "Unable to connect" on the
very first launch. This is expected — you need to log in:

1. Run `claude` inside the VM
2. Type `/login` at the prompt
3. Choose "Claude.ai" and follow the browser link
4. After login, run `claude` again — it connects normally from then on

---

## Daily workflow

```bash
ccvm      # enter the VM (starts it if stopped, injects credentials)
claude    # full Claude Code terminal UI — no permission prompts
```

Claude Code is configured to allow all actions without asking for confirmation.
The VM is the security boundary; prompts inside it add friction without
meaningful protection.

---

## Changing configuration

Edit `claude-vm.conf`, then re-run `./setup_claude_code`.

- Allowlist, ports, shared folder, installed tools → applied live.
- CPU / memory / disk → `limactl stop claude-dev` first, then re-run.

---

## Network security

**Squid proxy on your Mac** is the network enforcer. All traffic from the VM
routes through it via `HTTP_PROXY` env set inside the VM. Squid allows only the
domains listed in `claude-vm.conf` and blocks everything else.

Because enforcement runs on your Mac, VM root cannot modify or bypass it — even
a deliberately hostile process inside the VM can only reach what Squid allows.

The allowlist has two sections in `claude-vm.conf`:

- `PROTECTED_DOMAINS` — Anthropic API/auth/telemetry plus provisioning domains
  (apt, Docker, Node). Do not remove these or Claude Code will stop working.
- `ALLOWED_DOMAINS` — your development domains. Start narrow and add as needed.

The allowlist convention: `.example.com` matches the domain and all subdomains;
`host.example.com` matches that exact host.

Watch what the VM is reaching (including blocked attempts):

```bash
tail -f /usr/local/var/log/squid/access.log
```

---

## Credentials (summary — full detail in CREDENTIALS.md)

Values live only in the macOS keychain, never on disk.

```bash
./manage_credentials add github          # env, GITHUB_TOKEN (built-in default)
./manage_credentials add gcp             # env, mounts your JSON key for the session
./manage_credentials list
./manage_credentials remove github
```

For Anthropic on a Pro/Max plan, run `/login` once inside Claude Code — no
credential entry needed. Credentials are injected into the VM session in memory
only and are gone when you close the session.

---

## Shared folder

Set `SHARED_DIR` in `claude-vm.conf` to a folder on your Mac. It appears inside
the VM at `/home/claude/shared`, writable by the claude user.

```bash
SHARED_DIR="$HOME/code/my-project"
```

The setup script automatically sets the correct permissions (including an
inheritable macOS ACL) so that files you add to the folder later are
immediately writable from inside the VM — no manual `chmod` needed.

Keep the shared folder scoped to your current project. Claude can read and write
anything in it, including files on your Mac.

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

- `network` → reachable from another workstation at `http://<mac-name>.local:8888`
- `local` → your Mac only

Services inside the VM must bind to `0.0.0.0` (not `127.0.0.1`) to be reachable
from outside. Your Mac's `.local` hostname is stable; the WiFi IP can change.

---

## Security guarantees and honest limits

**Absolute:**
- The VM's filesystem is fully isolated from your Mac. Claude cannot see your
  home directory, SSH keys, browser, or any Mac files.
- Credential values are never written to disk; they live in the keychain and
  exist in session memory only.

**Strong (covers the realistic threat):**
- Network enforcement is on the Mac, outside VM root's reach. Stops accidental
  or prompt-injected egress to unlisted domains entirely.

**Conscious trade-offs:**
- `network`-labelled ports are reachable by any device on your WiFi. Fine for
  local dev with no real data; be aware on shared/public networks.
- Claude Code auto-updates from Anthropic's servers (on the allowlist). You are
  trusting Anthropic's release process on an ongoing basis.
- Docker inside the VM is root-equivalent within the VM. A deliberately hostile
  process could manipulate in-VM state; Mac-side Squid enforcement is unaffected.
- The shared folder is a deliberate opening between Mac and VM. Keep it scoped.
- All Claude Code permission prompts are suppressed. The VM boundary is the
  safety layer, not in-app prompts.

**Trust root:** Lima and Squid run under your Mac admin account — the same trust
assumption as any software you run.

---

## Requirements

- Intel Mac, macOS 13.0 (Ventura) or later
- Paid Anthropic plan (Pro / Max / Team / Enterprise / Console)
- ~10 GB free disk
- Homebrew (the setup script installs it if missing)

---

## Useful commands

```bash
limactl list                               # VM status
limactl stop claude-dev                    # shut down
limactl start claude-dev                   # bring back
limactl delete claude-dev                  # destroy (rebuild with ./setup_claude_code)
tail -f /usr/local/var/log/squid/access.log  # live network log
```
