#!/usr/bin/env bash
# The copyright-safe Jellyfin demo server for the store screenshots (README.md).
#
#   demo-server.sh all        # everything below, in order (idempotent)
#   demo-server.sh media      # build/media: art from film frames, placeholder videos, NFOs
#   demo-server.sh up         # create/start the Lima VM "matine-demo" (docker inside)
#   demo-server.sh stack      # Jellyfin + Caddy (compose.yaml) in the VM, then export Caddy's root CA
#   demo-server.sh provision  # wizard, libraries, users, watch state -> build/ids.json
#   demo-server.sh ca         # export Caddy's root CA to build/caddy-root.crt
#   demo-server.sh check      # curl --cacert the system info endpoint over HTTPS
#   demo-server.sh down       # stop the VM (data stays); `destroy` deletes it
set -euo pipefail
cd "$(dirname "$0")"
VM=matine-demo
SERVER=https://localhost:8920
CA=build/caddy-root.crt
mkdir -p build

lima() { limactl shell "$VM" "$@"; }

media() {
    [[ -x build/venv/bin/python ]] || { uv venv -q build/venv && uv pip install -q --python build/venv/bin/python pillow; }
    build/venv/bin/python build-media.py "$@"
}

up() {
    if ! limactl list -q | grep -qx "$VM"; then
        mkdir -p build/media
        sed "s#__MEDIA__#$PWD/build/media#" lima.yaml > build/lima.yaml
        limactl start --name "$VM" --tty=false build/lima.yaml
    else
        limactl start "$VM" 2>/dev/null || true
    fi
}

ca() {
    for _ in $(seq 30); do
        lima docker cp matine-demo-caddy-1:/data/caddy/pki/authorities/local/root.crt - 2>/dev/null | tar -xO > "$CA" && [[ -s $CA ]] && break
        sleep 2
    done
    openssl x509 -in "$CA" -noout -subject -enddate
}

stack() {
    lima docker compose -p matine-demo -f - up -d < compose.yaml
    ca
}

check() {
    curl -fsS --cacert "$CA" "$SERVER/System/Info/Public"; echo
}

provision() { python3 provision.py --server "$SERVER" --cacert "$CA"; }

case "${1:-all}" in
    all) media; up; stack; provision; check ;;
    media) shift; media "$@" ;;
    up) up ;;
    stack) stack ;;
    provision) provision ;;
    ca) ca ;;
    check) check ;;
    down) limactl stop "$VM" ;;
    destroy) limactl delete -f "$VM" ;;
    *) sed -n '2,12p' "$0"; exit 2 ;;
esac
