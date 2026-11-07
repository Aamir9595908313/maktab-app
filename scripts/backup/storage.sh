#!/usr/bin/env bash
# Downloads every uploaded file from Supabase Storage (private buckets too).
set -euo pipefail
: "${SUPABASE_URL:?}" "${SUPABASE_SERVICE_KEY:?}"
OUT=out/storage
mkdir -p "$OUT"
H=(-H "Authorization: Bearer $SUPABASE_SERVICE_KEY" -H "apikey: $SUPABASE_SERVICE_KEY")

walk() { # bucket prefix
  local bucket="$1" prefix="$2"
  curl -sS "${H[@]}" -H 'Content-Type: application/json' -X POST \
    -d "{\"prefix\":\"$prefix\",\"limit\":1000,\"offset\":0}" \
    "$SUPABASE_URL/storage/v1/object/list/$bucket" | jq -c '.[]' | while read -r item; do
      name=$(echo "$item" | jq -r '.name'); id=$(echo "$item" | jq -r '.id')
      path="${prefix:+$prefix/}$name"
      if [ "$id" = "null" ]; then walk "$bucket" "$path"; else
        mkdir -p "$OUT/$bucket/$(dirname "$path")"
        curl -sS "${H[@]}" -o "$OUT/$bucket/$path" "$SUPABASE_URL/storage/v1/object/$bucket/$path"
      fi
    done
}
for b in $(curl -sS "${H[@]}" "$SUPABASE_URL/storage/v1/bucket" | jq -r '.[].id'); do walk "$b" ""; done
echo "storage files: $(find "$OUT" -type f | wc -l)"
