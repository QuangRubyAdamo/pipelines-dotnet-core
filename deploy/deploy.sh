#!/usr/bin/env bash
# Deploy or roll back one instance (dev | stage) of pipelines-dotnet-core on this host.
#
# Runs as root via a sudoers rule that allows the Azure Pipelines agent user to
# call ONLY the root-owned copy at /opt/pipelines-dotnet-core/bin/deploy.sh.
# Never point sudo at a copy coming from the build artifact: whoever can change
# the repo would then own the server.
#
# Usage:
#   deploy.sh <dev|stage> <package.tar.gz> <version>   deploy a release
#   deploy.sh <dev|stage> --rollback                   switch back to the previous release
#
# Layout per instance:
#   /opt/pipelines-dotnet-core/<instance>/releases/<version>/   extracted releases
#   /opt/pipelines-dotnet-core/<instance>/current -> releases/<version>
#   /etc/pipelines-dotnet-core/<instance>.env                   ASPNETCORE_URLS, ASPNETCORE_ENVIRONMENT, secrets
set -euo pipefail

APP=pipelines-dotnet-core
KEEP=5                 # releases kept per instance, including the active one
HEALTH_ATTEMPTS=20     # x 3s = up to 60s for the app to answer

die() { echo "ERROR: $*" >&2; exit 1; }

INSTANCE=${1:-}
case "$INSTANCE" in
  dev|stage) ;;
  *) die "usage: $0 <dev|stage> <package.tar.gz> <version> | $0 <dev|stage> --rollback" ;;
esac

BASE=/opt/$APP/$INSTANCE
RELEASES=$BASE/releases
SERVICE=$APP@$INSTANCE
ENV_FILE=/etc/$APP/$INSTANCE.env

[ -d "$RELEASES" ] || die "$RELEASES missing; run setup-server.sh $INSTANCE first"
[ -f "$ENV_FILE" ] || die "$ENV_FILE missing; run setup-server.sh $INSTANCE first"

current_release() { [ -L "$BASE/current" ] && readlink -f "$BASE/current" || true; }

# Atomically repoint "current" (rename over the old symlink), then restart.
activate() {
  ln -sfn "$1" "$BASE/current.tmp"
  mv -Tf "$BASE/current.tmp" "$BASE/current"
  systemctl restart "$SERVICE"
}

# Health check against the first URL in ASPNETCORE_URLS (Kestrel bound to localhost).
wait_healthy() {
  local url
  url=$(grep -E '^ASPNETCORE_URLS=' "$ENV_FILE" | cut -d= -f2- | cut -d';' -f1)
  [ -n "$url" ] || die "ASPNETCORE_URLS not set in $ENV_FILE"
  for _ in $(seq 1 "$HEALTH_ATTEMPTS"); do
    curl -fsS -o /dev/null "$url/" && return 0
    sleep 3
  done
  return 1
}

# Releases newest-deployed first (each release dir is stamped with its deploy time).
releases_by_age() { ls -1dt "$RELEASES"/*/ 2>/dev/null | sed 's:/$::' || true; }

# Delete old releases beyond KEEP, never the active one.
prune() {
  local active
  active=$(current_release)
  releases_by_age | tail -n +$((KEEP + 1)) | while read -r dir; do
    [ "$dir" = "$active" ] || rm -rf -- "$dir"
  done
}

if [ "${2:-}" = "--rollback" ]; then
  active=$(current_release)
  # The release deployed just before the active one; repeated rollbacks walk further back.
  previous=$(releases_by_age | awk -v a="$active" 'found { print; exit } $0 == a { found = 1 }')
  [ -n "$previous" ] || die "no previous release to roll back to"
  activate "$previous"
  wait_healthy || die "rolled back to $previous but it is not healthy either"
  echo "Rolled back $INSTANCE to $(basename "$previous")"
  exit 0
fi

PACKAGE=${2:-}
VERSION=${3:-}
[ -f "$PACKAGE" ] || die "package not found: $PACKAGE"
# Version becomes a directory name under a root-owned tree: allow a safe charset only.
[[ "$VERSION" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid version: $VERSION"

DEST=$RELEASES/$VERSION
PREVIOUS=$(current_release)

if [ "$DEST" = "$PREVIOUS" ]; then
  echo "$VERSION is already active on $INSTANCE; nothing to do"
  exit 0
fi

rm -rf -- "$DEST"
mkdir -p "$DEST"
tar -xzf "$PACKAGE" -C "$DEST"
# tar restores the archive's own mtime onto DEST; stamp the deploy time instead
# so release ordering (prune, --rollback) follows deploy order.
touch "$DEST"
# Root-owned and read-only for the service account: the app cannot modify its own binaries.
chown -R root:root "$DEST"
chmod -R u=rwX,go=rX "$DEST"

activate "$DEST"

if wait_healthy; then
  prune
  echo "Deployed $VERSION to $INSTANCE"
  exit 0
fi

echo "Health check failed for $VERSION on $INSTANCE" >&2
# Drop the broken release so a later --rollback cannot land on it.
if [ -n "$PREVIOUS" ] && [ -d "$PREVIOUS" ]; then
  activate "$PREVIOUS"
  rm -rf -- "$DEST"
  if wait_healthy; then
    echo "Restored previous release $(basename "$PREVIOUS"); service is healthy" >&2
  else
    echo "Restored previous release $(basename "$PREVIOUS") but it is NOT healthy" >&2
  fi
else
  rm -rf -- "$DEST"
  echo "No previous release to restore; $INSTANCE is down" >&2
fi
exit 1
