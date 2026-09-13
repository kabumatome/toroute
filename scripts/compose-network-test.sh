#!/usr/bin/env bash
set -Eeuo pipefail
image=${1:-toroute:ci}; probe=${2:-toroute-netprobe:ci}; project="toroute-network-${RANDOM}-${RANDOM}"
export TOROUTE_TEST_IMAGE=$image TOROUTE_PROBE_IMAGE=$probe
cleanup(){ docker compose -p "$project" -f tests/compose-network.yml down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker compose -p "$project" -f tests/compose-network.yml up -d toroute egress-target >/dev/null
client="${project}_client";egress="${project}_egress"
target_id=$(docker compose -p "$project" -f tests/compose-network.yml ps -q egress-target)
target_ip=$(docker inspect --format "{{(index .NetworkSettings.Networks \"$egress\").IPAddress}}" "$target_id")
[[ $target_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "failed to resolve deterministic egress target IP" >&2; exit 1; }
reached=false
for _ in {1..30}; do
  if docker run --rm --network "$client" "$probe" --timeout 1s --expect success toroute:9050; then reached=true; break; fi
  sleep 1
done
[[ $reached == true ]] || { echo 'client network could not reach ToRoute SOCKS listener' >&2; exit 1; }
docker run --rm --network "$client" "$probe" --timeout 2s --expect failure "$target_ip:8080"
docker run --rm --network "$egress" "$probe" --timeout 2s --expect success "$target_ip:8080"
echo 'Compose network isolation tests passed'
