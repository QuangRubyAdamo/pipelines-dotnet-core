#!/usr/bin/env bash
# Deploy one instance (dev | stage) of pipelines-dotnet-core as a Docker container.
# Installed on the Droplet at /opt/pipelines-dotnet-core/bin/ by setup-droplet.sh and
# called over SSH by Azure DevOps as the "deploy" user (member of the docker group):
#
#   deploy-container.sh <dev|stage> <registry>/<repository>:<tag>
#
# Order of operations, so a bad image never takes down the running app:
#   1. pull the exact tag built by the pipeline run
#   2. start it as a throwaway "candidate" on a random localhost port and health-check it
#   3. only then replace the running container (a few seconds of downtime)
#   4. if the replacement is unhealthy, restore the previously running image
#
# Per-instance settings (root-owned, created by setup-droplet.sh):
#   /etc/pipelines-dotnet-core/<instance>.conf  IMAGE_REPOSITORY, HOST_PORT, BIND_ADDRESS
#   /etc/pipelines-dotnet-core/<instance>.env   app environment/secrets passed to the container
set -euo pipefail

CONFIG_DIR=/etc/pipelines-dotnet-core
LOCK_DIR=/run/lock
CONTAINER_PORT=8080      # matches ASPNETCORE_URLS in the Dockerfile
HEALTH_PATH=/health
HEALTH_ATTEMPTS=30       # x 2s
KEEP_IMAGES=5            # local images of the repository kept for quick restores

die() { echo "ERROR: $*" >&2; exit 1; }

INSTANCE=${1:-}
IMAGE=${2:-}
case "$INSTANCE" in
  dev|stage) ;;
  *) die "usage: $0 <dev|stage> <registry>/<repository>:<tag>" ;;
esac

CONF=$CONFIG_DIR/$INSTANCE.conf
APP_ENV=$CONFIG_DIR/$INSTANCE.env
[ -r "$CONF" ] || die "$CONF not readable; run setup-droplet.sh first"
[ -r "$APP_ENV" ] || die "$APP_ENV not readable; run setup-droplet.sh first"
# shellcheck source=/dev/null
. "$CONF"
: "${IMAGE_REPOSITORY:?must be set in $CONF}" "${HOST_PORT:?must be set in $CONF}"
BIND_ADDRESS=${BIND_ADDRESS:-127.0.0.1}

# Only accept images from the configured repository, with a plain tag.
case "$IMAGE" in
  "$IMAGE_REPOSITORY":*) ;;
  *) die "image must be $IMAGE_REPOSITORY:<tag>, got '$IMAGE'" ;;
esac
TAG=${IMAGE#"$IMAGE_REPOSITORY":}
[[ "$TAG" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid tag: '$TAG'"

NAME=pipelines-dotnet-core-$INSTANCE
CANDIDATE=$NAME-candidate
# Health checks go to the address the app is published on (localhost when bound to all interfaces).
HEALTH_HOST=$BIND_ADDRESS
[ "$HEALTH_HOST" = "0.0.0.0" ] && HEALTH_HOST=127.0.0.1

# One deploy per instance at a time (two quick pushes would otherwise race on the container name).
exec 9>"$LOCK_DIR/$NAME.lock"
flock -w 600 9 || die "another deploy of $INSTANCE is still running"

# run_container <name> <image> <publish spec> <restart policy>
run_container() {
  docker run -d --name "$1" \
    --restart "$4" \
    --env-file "$APP_ENV" \
    -p "$3" \
    --read-only --tmpfs /tmp \
    --cap-drop ALL --security-opt no-new-privileges \
    --memory 512m \
    "$2" >/dev/null
}

wait_healthy() {
  for _ in $(seq 1 "$HEALTH_ATTEMPTS"); do
    curl -fsS -o /dev/null --max-time 3 "$1" && return 0
    sleep 2
  done
  return 1
}

echo "Pulling $IMAGE"
docker pull -q "$IMAGE" >/dev/null || die "docker pull failed (is the deploy user logged in to the registry?)"

echo "Validating $IMAGE as a candidate container"
docker rm -f "$CANDIDATE" >/dev/null 2>&1 || true
run_container "$CANDIDATE" "$IMAGE" "127.0.0.1::$CONTAINER_PORT" no || die "candidate container failed to start"
candidate_port=$(docker port "$CANDIDATE" "$CONTAINER_PORT/tcp" | head -n 1 | sed 's/.*://')
if ! wait_healthy "http://127.0.0.1:$candidate_port$HEALTH_PATH"; then
  echo "--- candidate logs ---" >&2
  docker logs --tail 50 "$CANDIDATE" >&2 || true
  docker rm -f "$CANDIDATE" >/dev/null 2>&1 || true
  die "new image failed its health check; the running $INSTANCE container was not touched"
fi
docker rm -f "$CANDIDATE" >/dev/null

PREVIOUS=$(docker inspect -f '{{.Config.Image}}' "$NAME" 2>/dev/null || true)
echo "Switching $NAME from ${PREVIOUS:-<none>} to $IMAGE"
docker rm -f "$NAME" >/dev/null 2>&1 || true

if run_container "$NAME" "$IMAGE" "$BIND_ADDRESS:$HOST_PORT:$CONTAINER_PORT" unless-stopped \
   && wait_healthy "http://$HEALTH_HOST:$HOST_PORT$HEALTH_PATH"; then
  # Remove old local images beyond KEEP_IMAGES; images used by a container are kept by docker.
  docker images "$IMAGE_REPOSITORY" --format '{{.Repository}}:{{.Tag}}' | tail -n +$((KEEP_IMAGES + 1)) \
    | while read -r old; do docker rmi "$old" >/dev/null 2>&1 || true; done
  echo "Deployed $IMAGE to $INSTANCE (http://$HEALTH_HOST:$HOST_PORT)"
  exit 0
fi

echo "--- $NAME logs ---" >&2
docker logs --tail 50 "$NAME" >&2 || true
docker rm -f "$NAME" >/dev/null 2>&1 || true
if [ -n "$PREVIOUS" ] && [ "$PREVIOUS" != "$IMAGE" ]; then
  echo "Restoring previous image $PREVIOUS" >&2
  if run_container "$NAME" "$PREVIOUS" "$BIND_ADDRESS:$HOST_PORT:$CONTAINER_PORT" unless-stopped \
     && wait_healthy "http://$HEALTH_HOST:$HOST_PORT$HEALTH_PATH"; then
    echo "Restored $PREVIOUS; it is healthy" >&2
  else
    echo "Restored $PREVIOUS but it is NOT healthy" >&2
  fi
else
  echo "No previous image to restore; $INSTANCE is down" >&2
fi
die "deploy of $IMAGE to $INSTANCE failed"
