#!/bin/bash
# =============================================================================
# vm-provision.sh  —  runs INSIDE the VM as root (invoked by setup_claude_code)
# =============================================================================
# Installs the dev stack and points the 'claude' user's tooling at the Mac-side
# Squid proxy (reachable at host.lima.internal). NO proxy or firewall runs
# inside the VM — all network enforcement lives on the Mac.
# Idempotent. Accepts KEY=VALUE args.
# =============================================================================

set -eo pipefail
export DEBIAN_FRONTEND=noninteractive

PROXY_PORT="3128"; INSTALL_NODE="true"; INSTALL_PYTHON="true"
INSTALL_DOCKER="true"; INSTALL_GCLOUD="false"
GATEWAY_IP="192.168.105.1"   # socket_vmnet gateway; overridden by setup script
for arg in "$@"; do case "$arg" in *=*) export "${arg?}";; esac; done

log() { printf '\033[1;36m[vm]\033[0m %s\n' "$*"; }
CLAUDE_USER="claude"
# Use socket_vmnet gateway (192.168.105.1), NOT host.lima.internal which
# resolves to the usernet gateway (192.168.5.2) where Squid is not listening.
PROXY="http://${GATEWAY_IP}:${PROXY_PORT}"

# Set proxy BEFORE any network commands so apt, curl, and all tools route
# through Squid on the Mac.
export HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY" http_proxy="$PROXY" https_proxy="$PROXY"
export NO_PROXY="localhost,127.0.0.1,::1,host.lima.internal"
mkdir -p /etc/apt/apt.conf.d
printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' "$PROXY" "$PROXY" \
  > /etc/apt/apt.conf.d/99ccvm-proxy

# 1. Base packages
log "Installing base packages..."
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg git sudo >/dev/null

# Non-root claude user
if ! id "$CLAUDE_USER" >/dev/null 2>&1; then
  log "Creating user '$CLAUDE_USER'..."
  useradd -m -s /bin/bash "$CLAUDE_USER"
fi
# Lima pre-creates /home/claude (as root) for the shared mount, so useradd
# warns and skips skel files (.bashrc, .profile etc.). Copy them if missing.
for _f in .bashrc .bash_logout .profile; do
  [ -f "/home/$CLAUDE_USER/$_f" ] || cp "/etc/skel/$_f" "/home/$CLAUDE_USER/$_f" 2>/dev/null || true
done
# Chown the home dir and dotfiles; skip the shared submount (Mac-owned).
chown "$CLAUDE_USER:$CLAUDE_USER" "/home/$CLAUDE_USER"
install -d -o "$CLAUDE_USER" -g "$CLAUDE_USER" "/home/$CLAUDE_USER/projects"
# The shared folder is a 9p mount owned by the Mac user (different uid from claude).
# chmod 777 here sets the in-VM permissions so claude can read and write it.
if [ -d "/home/$CLAUDE_USER/shared" ]; then
  chmod 777 "/home/$CLAUDE_USER/shared"
fi

# 3. Proxy env for everyone (so installs below also go through the Mac proxy
#    once it's enforced; during first provisioning Lima's NAT is still open).
cat > /etc/profile.d/cc-proxy.sh <<ENV
export HTTP_PROXY="${PROXY}"
export HTTPS_PROXY="${PROXY}"
export http_proxy="${PROXY}"
export https_proxy="${PROXY}"
export NO_PROXY="localhost,127.0.0.1,::1,host.lima.internal"
export no_proxy="localhost,127.0.0.1,::1,host.lima.internal"
# Ensure ~/.local/bin (where claude binary lives) is always on PATH
export PATH="\$HOME/.local/bin:\$PATH"
ENV
chmod 644 /etc/profile.d/cc-proxy.sh

# 4. Docker
if [ "$INSTALL_DOCKER" = "true" ]; then
  if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker..."; curl -fsSL https://get.docker.com | sh >/dev/null
  fi
  systemctl enable --now docker >/dev/null 2>&1 || true
  usermod -aG docker "$CLAUDE_USER"
  # Route Docker daemon pulls through the Mac proxy too.
  install -d /etc/systemd/system/docker.service.d
  cat > /etc/systemd/system/docker.service.d/http-proxy.conf <<DP
[Service]
Environment="HTTP_PROXY=${PROXY}"
Environment="HTTPS_PROXY=${PROXY}"
Environment="NO_PROXY=localhost,127.0.0.1,::1,host.lima.internal"
DP
  systemctl daemon-reload 2>/dev/null || true
  systemctl restart docker 2>/dev/null || true
fi

# 5. Node + Python
if [ "$INSTALL_NODE" = "true" ] && ! command -v node >/dev/null 2>&1; then
  log "Installing Node.js LTS..."
  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - >/dev/null 2>&1
  apt-get install -y -qq nodejs >/dev/null
fi
if [ "$INSTALL_PYTHON" = "true" ]; then
  log "Installing Python toolchain..."
  apt-get install -y -qq python3 python3-pip python3-venv build-essential >/dev/null
fi

# 6. gcloud (optional)
if [ "$INSTALL_GCLOUD" = "true" ] && ! command -v gcloud >/dev/null 2>&1; then
  log "Installing Google Cloud CLI..."
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    > /etc/apt/sources.list.d/google-cloud-sdk.list
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
  apt-get update -qq && apt-get install -y -qq google-cloud-cli >/dev/null
fi

# 7. git proxy for the claude user
sudo -iu "$CLAUDE_USER" git config --global http.proxy  "$PROXY" || true
sudo -iu "$CLAUDE_USER" git config --global https.proxy "$PROXY" || true

# 8. Claude Code for the claude user
# Write the install steps to a file and execute the file as the claude user.
# (Passing a multi-line script inline via `bash -c '...'` is fragile across the
#  limactl -> sudo -> sudo -iu boundaries; a file avoids all quoting issues.)
log "Installing Claude Code for '$CLAUDE_USER'..."
cat > /tmp/cc-install.sh <<'INSTALL'
#!/bin/bash
set -e
if ! command -v claude >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/claude" ]; then
  curl -fsSL https://claude.ai/install.sh | bash
fi
INSTALL
chmod 0755 /tmp/cc-install.sh
chown "$CLAUDE_USER" /tmp/cc-install.sh
# -i gives a login shell (so the proxy env from /etc/profile.d is applied);
# running a file means no inline quoting to corrupt.
sudo -iu "$CLAUDE_USER" bash /tmp/cc-install.sh || {
  echo "[vm] First attempt failed; retrying once..."
  sudo -iu "$CLAUDE_USER" bash /tmp/cc-install.sh
}
rm -f /tmp/cc-install.sh

# Verify the install actually landed.
if sudo -iu "$CLAUDE_USER" bash -lc 'command -v claude >/dev/null 2>&1 || [ -x "$HOME/.local/bin/claude" ]'; then
  log "Claude Code installed for '$CLAUDE_USER'."
else
  log "WARNING: Claude Code did not install. Check the VM's network/proxy and re-run."
fi
log "Provisioning complete."
