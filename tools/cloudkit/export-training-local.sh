#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
config="$repo_root/.env.cloudkit.local"
if [ ! -f "$config" ]; then
  printf '%s\n' "missing $config" >&2
  exit 1
fi

# shellcheck disable=SC1090
. "$config"
: "${CLOUDKIT_KEY_ID:?CLOUDKIT_KEY_ID is required}"
: "${CLOUDKIT_PRIVATE_KEY:?CLOUDKIT_PRIVATE_KEY is required}"
export CLOUDKIT_KEY_ID CLOUDKIT_PRIVATE_KEY CLOUDKIT_CONTAINER CLOUDKIT_ENV

cd "$repo_root"
exec pnpm --filter @sift/cloudkit-tools export -- \
  --env "${CLOUDKIT_ENV:-production}" \
  --container "${CLOUDKIT_CONTAINER:-iCloud.com.alkinum.sift}" \
  --out "$repo_root/build/pipeline/remote-training.ndjson" "$@"
