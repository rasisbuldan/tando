#!/bin/bash
# test/offsite-r2-check.sh: tando's S3 client against a REAL bucket (Cloudflare R2 by default):
# the provider-compatibility subset of srv/offsite (the probe `tando backup offsite set` runs, put,
# head, get, range get, multipart upload and abort, list with paging and a delimiter, delete, the
# errors of a wrong secret and a missing bucket), under a throwaway prefix tando-check-<random>/
# that it deletes again. Nothing else in the bucket is touched. Needs Go (srv/go.mod).
#
#   R2_ACCOUNT_ID=... R2_BUCKET=... R2_ACCESS_KEY_ID=... R2_SECRET_ACCESS_KEY=... test/offsite-r2-check.sh
#
# Another S3 store: S3_ENDPOINT=https://... (and S3_REGION=...) instead of R2_ACCOUNT_ID. The
# token needs Object Read & Write on that bucket (docs/BACKUP.md, "Cloudflare R2, step by step").
# The secret is read from the environment only and never printed.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd -P) || exit 2
miss=""
[ -n "${R2_ACCOUNT_ID:-}${S3_ENDPOINT:-}" ] || miss="$miss R2_ACCOUNT_ID"
for v in R2_BUCKET R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY; do eval "[ -n \"\${$v:-}\" ]" || miss="$miss $v"; done
if [ -n "$miss" ]; then
  echo "offsite-r2-check: set$miss (see the comment at the top of this file)" >&2
  exit 2
fi
command -v go > /dev/null || { echo "offsite-r2-check: needs Go" >&2; exit 2; }
cd "$ROOT/srv" || exit 2
export GOTOOLCHAIN=local GOFLAGS=
exec go test -count=1 -v -run '^TestProviderLive$' ./offsite
