#!/usr/bin/env bash
set -Eeuo pipefail

# Prevent Git for Windows/MSYS from rewriting container-internal POSIX paths
# passed through docker.exe. These variables are harmless on native Linux.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

image=${1:?usage: docker-child-failure-test.sh IMAGE}
active_name=
cleanup() {
  if [[ -n $active_name ]]; then
    docker rm -f "$active_name" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

container_has_process() {
  local container=$1 process=$2
  docker exec "$container" /bin/sh -c '
    for comm in /proc/[0-9]*/comm; do
      IFS= read -r name < "$comm" || continue
      [ "$name" = "$1" ] && exit 0
    done
    exit 1
  ' probe "$process" >/dev/null 2>&1
}

wait_for_children() {
  local container=$1
  for _ in {1..100}; do
    if container_has_process "$container" tor && container_has_process "$container" privoxy; then
      return 0
    fi
    if [[ $(docker inspect --format '{{.State.Running}}' "$container") != true ]]; then
      docker logs "$container" >&2 || true
      echo 'container exited before both children started' >&2
      return 1
    fi
    sleep 0.1
  done
  docker logs "$container" >&2 || true
  echo 'timed out waiting for Tor and Privoxy children' >&2
  return 1
}

terminate_child() {
  local container=$1 process=$2
  docker exec "$container" /bin/sh -c '
    for comm in /proc/[0-9]*/comm; do
      IFS= read -r name < "$comm" || continue
      if [ "$name" = "$1" ]; then
        pid=${comm#/proc/}
        pid=${pid%/comm}
        kill -TERM "$pid"
        exit 0
      fi
    done
    exit 1
  ' probe "$process"
}

run_case() {
  local failed_child=$1 exit_code logs
  active_name="toroute-child-${failed_child}-${RANDOM}-${RANDOM}"
  docker run -d --name "$active_name" --network none --read-only \
    --cap-drop=ALL --security-opt=no-new-privileges --pids-limit 128 \
    --tmpfs "/run/toroute:uid=65532,gid=65532,mode=0700" \
    --tmpfs "/var/lib/toroute:uid=65532,gid=65532,mode=0700" \
    -e TOROUTE_HTTP_ENABLED=true "$image" >/dev/null

  wait_for_children "$active_name"
  terminate_child "$active_name" "$failed_child"
  exit_code=$(docker wait "$active_name")
  logs=$(docker logs "$active_name" 2>&1)

  if [[ $exit_code == 0 ]]; then
    echo "$logs" >&2
    echo "$failed_child failure incorrectly produced container exit code 0" >&2
    return 1
  fi
  if ! grep -Fq "$failed_child exited" <<<"$logs"; then
    echo "$logs" >&2
    echo "missing supervised $failed_child failure diagnostic" >&2
    return 1
  fi
  if [[ $(docker inspect --format '{{.State.Running}}' "$active_name") != false ]]; then
    echo "container remained running after $failed_child failure" >&2
    return 1
  fi

  docker rm "$active_name" >/dev/null
  active_name=
  echo "$failed_child failure supervision passed"
}

run_case privoxy
run_case tor
echo 'container child-failure tests passed'
