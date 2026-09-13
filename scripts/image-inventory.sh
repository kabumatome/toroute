#!/usr/bin/env bash
set -Eeuo pipefail
image=${1:?usage: image-inventory.sh IMAGE OUTPUT_JSON}
output=${2:?usage: image-inventory.sh IMAGE OUTPUT_JSON}
command -v docker >/dev/null || { echo 'docker is required' >&2; exit 1; }
mkdir -p "$(dirname "$output")"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
docker image inspect "$image" >"$tmp/inspect.json"
docker run --rm --entrypoint /bin/sh "$image" -c 'cat /etc/os-release' >"$tmp/os-release"
docker run --rm --entrypoint /usr/bin/dpkg-query "$image" -W '-f=${binary:Package}\t${Version}\t${Installed-Size}\n' >"$tmp/packages.tsv"
python3 - "$image" "$tmp/inspect.json" "$tmp/os-release" "$tmp/packages.tsv" "$output" <<'PY2'
import json, pathlib, sys
image, inspect_path, os_release_path, packages_path, output = sys.argv[1:]
inspect = json.loads(pathlib.Path(inspect_path).read_text(encoding="utf-8"))
if not isinstance(inspect, list) or len(inspect) != 1:
    raise SystemExit("docker image inspect returned an unexpected document")
item = inspect[0]; config = item.get("Config") or {}; size = item.get("Size")
if not isinstance(size, int) or size <= 0: raise SystemExit("image Size is missing")
os_release = {}
for line in pathlib.Path(os_release_path).read_text(encoding="utf-8").splitlines():
    if "=" in line:
        key, value = line.split("=", 1); os_release[key] = value.strip().strip('"')
packages = []; installed_kib = 0
for number, line in enumerate(pathlib.Path(packages_path).read_text(encoding="utf-8").splitlines(), 1):
    parts = line.split("\t")
    if len(parts) != 3: raise SystemExit(f"invalid package inventory line {number}")
    name, version, installed = parts
    try: installed_value = int(installed)
    except ValueError as exc: raise SystemExit(f"invalid Installed-Size on line {number}") from exc
    packages.append({"name": name, "version": version, "installed_size_kib": installed_value}); installed_kib += installed_value
packages.sort(key=lambda package: package["name"])
result = {"schema_version":1,"image_reference":image,"image_id":item.get("Id",""),"image_size_bytes":size,
"os":item.get("Os",""),"architecture":item.get("Architecture",""),"configured_user":config.get("User",""),
"entrypoint":config.get("Entrypoint") or [],"cmd":config.get("Cmd") or [],"exposed_ports":sorted((config.get("ExposedPorts") or {}).keys()),
"healthcheck":config.get("Healthcheck") or {},"distribution":os_release,"package_count":len(packages),
"package_installed_size_kib":installed_kib,"packages":packages}
pathlib.Path(output).write_text(json.dumps(result, indent=2, sort_keys=True)+"\n", encoding="utf-8")
print(f"image inventory written to {output}")
PY2
