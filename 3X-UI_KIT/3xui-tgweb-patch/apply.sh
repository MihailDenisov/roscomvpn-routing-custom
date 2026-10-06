#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=${1:-.}
EXPECTED=d57dcf824b6211201252da137b79029747f142f3
actual=$(git -C "$ROOT" rev-parse HEAD)
[[ "$actual" == "$EXPECTED" ]] || {
  echo "Refusing unexpected upstream revision: $actual (expected $EXPECTED)" >&2
  exit 2
}
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
python3 "$HERE/apply_backend_schema.py" "$ROOT"
python3 "$HERE/apply_backend_api.py" "$ROOT"
python3 "$HERE/apply_backend_list.py" "$ROOT"
python3 "$HERE/apply_frontend_api.py" "$ROOT"
python3 "$HERE/apply_frontend_form.py" "$ROOT"
python3 "$HERE/add_tests.py" "$ROOT"
gofmt -w "$ROOT/internal/database/model/model.go"   "$ROOT/internal/web/service/client_external_inbound.go"   "$ROOT/internal/web/service/client_external_inbound_test.go"   "$ROOT/internal/web/service/client.go"   "$ROOT/internal/web/service/client_lookup.go"   "$ROOT/internal/web/service/client_paging.go"   "$ROOT/internal/web/service/client_portable.go"   "$ROOT/internal/web/controller/client.go"

# Hard safety assertions: external provider must not enter Xray/inbound model paths.
if grep -Rni --exclude='*_test.go' -- 'tgweb\|Telegram WebProxy'     "$ROOT/internal/xray" "$ROOT/internal/database/model/inbound.go" 2>/dev/null; then
  echo "SAFETY FAILURE: TgWeb reference reached Xray/inbound core" >&2
  exit 3
fi
if grep -Rni -- 'externalInboundKeys' "$ROOT/internal/xray" 2>/dev/null; then
  echo "SAFETY FAILURE: external inbound keys reached Xray package" >&2
  exit 4
fi

echo "Patch applied. Production installation is intentionally NOT performed."
