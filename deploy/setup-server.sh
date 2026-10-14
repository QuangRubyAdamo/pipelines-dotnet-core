#!/usr/bin/env bash
# One-time preparation of an Ubuntu 22.04 host for pipelines-dotnet-core.
# Run as root from a checkout of this repo, naming the instances the host serves:
#   sudo ./deploy/setup-server.sh dev          # Dev server
#   sudo ./deploy/setup-server.sh stage        # Staging server
#   sudo ./deploy/setup-server.sh dev stage    # one host serving both
# Re-running is safe: existing env files are kept, scripts/units are refreshed.
set -euo pipefail

APP=pipelines-dotnet-core
APP_USER=pipelines-app   # runs the app, no login
AGENT_USER=azagent       # runs the Azure Pipelines agent
HERE=$(cd "$(dirname "$0")" && pwd)

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ $# -gt 0 ] || { echo "usage: $0 <dev|stage> [dev|stage]" >&2; exit 1; }

# Kestrel port and ASP.NET Core environment per instance.
port_of() { case "$1" in dev) echo 5000 ;; stage) echo 5001 ;; esac; }
aspnet_env_of() { case "$1" in dev) echo Development ;; stage) echo Staging ;; esac; }

for instance in "$@"; do
  case "$instance" in dev|stage) ;; *) echo "unknown instance: $instance" >&2; exit 1 ;; esac
done

# The app targets net6.0; Ubuntu 22.04 ships aspnetcore-runtime-6.0 in its own archive.
apt-get update
apt-get install -y aspnetcore-runtime-6.0 curl

id "$APP_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$APP_USER"
id "$AGENT_USER" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$AGENT_USER"

install -d -o root -g root -m 755 "/opt/$APP/bin" "/etc/$APP"
install -o root -g root -m 755 "$HERE/deploy.sh" "/opt/$APP/bin/deploy.sh"
install -o root -g root -m 644 "$HERE/$APP@.service" "/etc/systemd/system/$APP@.service"

for instance in "$@"; do
  install -d -o root -g root -m 755 "/opt/$APP/$instance/releases"
  env_file="/etc/$APP/$instance.env"
  if [ ! -f "$env_file" ]; then
    install -o root -g root -m 600 /dev/null "$env_file"
    cat > "$env_file" <<EOF
ASPNETCORE_URLS=http://127.0.0.1:$(port_of "$instance")
ASPNETCORE_ENVIRONMENT=$(aspnet_env_of "$instance")
EOF
  fi
  systemctl enable "$APP@$instance"   # started by the first deploy
done

# The agent may run exactly one command as root: the deploy script above.
sudoers=/etc/sudoers.d/$AGENT_USER-$APP
echo "$AGENT_USER ALL=(root) NOPASSWD: /opt/$APP/bin/deploy.sh" > "$sudoers"
chmod 440 "$sudoers"
visudo -cf "$sudoers"

systemctl daemon-reload

cat <<EOF

Host ready for: $*
Next: register this VM in the Azure DevOps Environment(s)
  Pipelines > Environments > pipelines-dotnet-core-<dev|stage> > Add resource > Virtual machines > Linux
  - copy the registration script and run it as '$AGENT_USER' (sudo -iu $AGENT_USER)
  - when prompted for tags, enter: pipelines-dotnet-core
Kestrel listens on 127.0.0.1 only; put Nginx in front to expose it.
EOF
