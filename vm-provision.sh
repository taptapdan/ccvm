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
for arg in "$@"; do case "$arg" in *=*) export "${arg?}";; esac; done

log() { printf '\033[1;36m[vm]\033[0m %s\n' "$*"; }
CLAUDE_USER="claude"
PROXY="http://host.lima.internal:${PROXY_PORT}"

# 1. Base packages (network is open during provisioning — Lima default)
log "Installing base packages..."
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg git sudo >/dev/null

# 2. Non-root claude user
if ! id "$CLAUDE_USER" >/dev/null 2>&1; then
  log "Creating user '$CLAUDE_USER'..."
  useradd -m -s /bin/bash "$CLAUDE_USER"
fi
install -d -o "$CLAUDE_USER" -g "$CLAUDE_USER" "/home/$CLAUDE_USER/projects"

# 3. Proxy env for everyone (so installs below also go through the Mac proxy
#    once it's enforced; during first provisioning Lima's NAT is still open).
cat > /etc/profile.d/cc-proxy.sh <<ENV
export HTTP_PROXY="${PROXY}"
export HTTPS_PROXY="${PROXY}"
export http_proxy="${PROXY}"
export https_proxy="${PROXY}"
export NO_PROXY="localhost,127.0.0.1,::1,host.lima.internal"
export no_proxy="localhost,127.0.0.1,::1,host.lima.internal"
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
log "Installing Claude Code for '$CLAUDE_USER'..."
sudo -iu "$CLAUDE_USER" bash -c '
  if ! command -v claude >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/claude" ]; then
    curl -fsSL https://claude.ai/install.sh | bash
  fi
'
log "Provisioning complete."
