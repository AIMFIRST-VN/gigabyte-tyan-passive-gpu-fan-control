#!/usr/bin/env bash
# Resumable OCI image pull over a FLAKY/slow link, then load into local Docker.
# Downloads each blob with aria2c (-c continue, multi-conn) against ghcr's signed
# CDN URLs, refreshing token/URL on drops so a huge layer accumulates across
# reconnects (plain `docker pull`/`skopeo` restart the blob and never finish).
# Usage: aria-oci-pull.sh [registry] [repo] [tag] [arch]
set -uo pipefail
REG="${1:-ghcr.io}"; REPO="${2:-ggml-org/llama.cpp}"; TAG="${3:-server-rocm}"; ARCH="${4:-amd64}"
DIR="/data/rocm-oci"; BLOBS="$DIR/blobs/sha256"; LOG="/var/log/aria-pull.log"
mkdir -p "$BLOBS"; : > "$LOG"
ACC='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'
log(){ echo "[$(date +%T)] $*" >> "$LOG"; }
tok(){ curl -s "https://$REG/token?scope=repository:$REPO:pull&service=$REG" | jq -r .token; }

T=$(tok)
IDX=$(curl -s -H "Authorization: Bearer $T" -H "Accept: $ACC" "https://$REG/v2/$REPO/manifests/$TAG")
MDIG=$(echo "$IDX" | jq -r --arg a "$ARCH" '.manifests[]?|select(.platform.architecture==$a and .platform.os=="linux")|.digest' | head -1)
if [ -z "$MDIG" ] || [ "$MDIG" = "null" ]; then MAN="$IDX"; else
  MAN=$(curl -s -H "Authorization: Bearer $T" -H "Accept: $ACC" "https://$REG/v2/$REPO/manifests/$MDIG"); fi
[ -z "$MDIG" ] || [ "$MDIG" = "null" ] && MDIG="sha256:$(printf '%s' "$MAN" | sha256sum | awk '{print $1}')"
printf '%s' "$MAN" > "$BLOBS/${MDIG#sha256:}"
MSIZE=$(stat -c%s "$BLOBS/${MDIG#sha256:}")
MMT=$(echo "$MAN" | jq -r '.mediaType // "application/vnd.oci.image.manifest.v1+json"')
echo '{"imageLayoutVersion":"1.0.0"}' > "$DIR/oci-layout"
printf '{"schemaVersion":2,"manifests":[{"mediaType":"%s","digest":"%s","size":%s}]}\n' "$MMT" "$MDIG" "$MSIZE" > "$DIR/index.json"
log "manifest $MDIG type=$MMT size=$MSIZE"

dl(){ # digest size
  local dig="$1" sz="$2" f="$BLOBS/${1#sha256:}" have url n=0
  have=0; [ -f "$f" ] && have=$(stat -c%s "$f")
  [ "$have" = "$sz" ] && { log "have ${dig:7:12}"; return 0; }
  log "get ${dig:7:12} ($((sz/1048576))MB)"
  while :; do
    have=0; [ -f "$f" ] && have=$(stat -c%s "$f"); [ "$have" = "$sz" ] && break
    T=$(tok)
    url=$(curl -s -o /dev/null -w '%{redirect_url}' -H "Authorization: Bearer $T" "https://$REG/v2/$REPO/blobs/$dig")
    if [ -n "$url" ]; then
      aria2c -c -x16 -s16 -k1M --retry-wait=5 --max-tries=30 --timeout=60 --summary-interval=15 -d "$BLOBS" -o "${dig#sha256:}" "$url" >>"$LOG" 2>&1
    else
      aria2c -c -x4 -s4 -k1M --retry-wait=5 --max-tries=30 --timeout=60 --summary-interval=15 --header="Authorization: Bearer $T" -d "$BLOBS" -o "${dig#sha256:}" "https://$REG/v2/$REPO/blobs/$dig" >>"$LOG" 2>&1
    fi
    n=$((n+1)); [ $n -gt 300 ] && { log "GIVE UP $dig after $n tries"; return 1; }
  done
  log "done ${dig:7:12}"
}

dl "$(echo "$MAN"|jq -r '.config.digest')" "$(echo "$MAN"|jq -r '.config.size')"
echo "$MAN" | jq -r '.layers[]|"\(.digest) \(.size)"' | while read -r d s; do dl "$d" "$s"; done

log "all blobs present -> assembling + loading into docker"
if skopeo copy oci:"$DIR" docker-daemon:"$REG/$REPO:$TAG" >>"$LOG" 2>&1; then log "IMAGE-LOADED-OK"; else log "LOAD-FAIL (digest mismatch? re-run to re-fetch)"; fi
