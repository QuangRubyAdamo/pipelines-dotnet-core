#!/usr/bin/env bash
# One-time preparation of an Ubuntu Droplet for pipelines-dotnet-core.
# Run as root from a checkout of this repo:
#
#   sudo ./deploy/setup-droplet.sh "<public key of the Azure DevOps deploy key>" dev [stage]
#
# Creates the "deploy" user that Azure DevOps logs in as, installs Docker and the
# deploy script, and writes per-instance settings. It deliberately does NOT change
# sshd or firewall settings (that could lock you out); see the setup guide.
# Re-running is safe: existing settings files are kept, the script is refreshed.
set -euo pipefail

APP=pipelines-dotnet-core
DEPLOY_USER=deploy
IMAGE_REPOSITORY=rafflesdemo.azurecr.io/$APP
HERE=$(cd "$(dirname "$0")" && pwd)

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ $# -ge 2 ] || { echo "usage: $0 \"<ssh public key>\" <dev|stage> [dev|stage]" >&2; exit 1; }
PUBKEY=$1; shift
case "$PUBKEY" in ssh-*|ecdsa-*) ;; *) echo "first argument must be an SSH public key" >&2; exit 1 ;; esac

# Host port and ASP.NET Core environment per instance; apps bind to localhost by default.
port_of() { case "$1" in dev) echo 8081 ;; stage) echo 8082 ;; esac; }
aspnet_env_of() { case "$1" in dev) echo Development ;; stage) echo Staging ;; esac; }

for instance in "$@"; do
  case "$instance" in dev|stage) ;; *) echo "unknown instance: $instance" >&2; exit 1 ;; esac
done

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y docker.io curl util-linux
systemctl enable --now docker 2>/dev/null || true

if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$DEPLOY_USER"
fi
# docker group = root-equivalent on this host; the deploy key must be dedicated and protected.
usermod -aG docker "$DEPLOY_USER"

home=$(getent passwd "$DEPLOY_USER" | cut -d: -f6)
install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" -m 700 "$home/.ssh"
touch "$home/.ssh/authorized_keys"
grep -qxF "$PUBKEY" "$home/.ssh/authorized_keys" || echo "$PUBKEY" >> "$home/.ssh/authorized_keys"
chown "$DEPLOY_USER:$DEPLOY_USER" "$home/.ssh/authorized_keys"
chmod 600 "$home/.ssh/authorized_keys"

install -d -o root -g root -m 755 "/opt/$APP/bin" "/etc/$APP"
install -o root -g root -m 755 "$HERE/deploy-container.sh" "/opt/$APP/bin/deploy-container.sh"

for instance in "$@"; do
  conf=/etc/$APP/$instance.conf
  if [ ! -f "$conf" ]; then
    cat > "$conf" <<EOF
IMAGE_REPOSITORY=$IMAGE_REPOSITORY
HOST_PORT=$(port_of "$instance")
# 127.0.0.1 = reachable only through a reverse proxy on this host (recommended).
# 0.0.0.0 publishes the port on every interface; Docker bypasses ufw, so restrict it with a DigitalOcean Cloud Firewall.
BIND_ADDRESS=127.0.0.1
EOF
    chmod 644 "$conf"
  fi
  env_file=/etc/$APP/$instance.env
  if [ ! -f "$env_file" ]; then
    # App settings and secrets for the container (KEY=VALUE per line); readable by root and the deploy user only.
    echo "ASPNETCORE_ENVIRONMENT=$(aspnet_env_of "$instance")" > "$env_file"
    chown "root:$DEPLOY_USER" "$env_file"
    chmod 640 "$env_file"
  fi
done

cat <<EOF

Droplet ready for: $*
Remaining manual step (needs the ACR pull credential, never put it in the repo):
  sudo -iu $DEPLOY_USER
  read -rsp 'ACR pull password: ' P; echo
  printf '%s' "\$P" | docker login ${IMAGE_REPOSITORY%%/*} --username <service-principal-appId> --password-stdin; unset P
  chmod 600 ~/.docker/config.json
EOF
