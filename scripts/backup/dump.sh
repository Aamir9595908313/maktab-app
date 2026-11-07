#!/usr/bin/env bash
# Runs inside a postgres:17 container. Writes the database export to /w/out.
set -euo pipefail
OUT=/w/out
mkdir -p "$OUT/csv"
STAMP="$(date -u +%Y-%m-%d)"

# 1) Full restorable dump of the app's schema + data (public).
pg_dump "$DB_URL" --no-owner --no-privileges --schema=public -Fc -f "$OUT/database_public.dump"

# 2) Login accounts (phone-number users) so people can be re-linked on restore.
pg_dump "$DB_URL" --no-owner --no-privileges --data-only --table=auth.users --table=auth.identities -f "$OUT/auth_users_identities.sql" || echo "auth export skipped (no permission)"

# 3) Human-readable CSV of every table + a row-count summary (counts only).
: > "$OUT/row_counts.txt"
for t in $(psql "$DB_URL" -Atc "select tablename from pg_tables where schemaname='public' order by 1"); do
  psql "$DB_URL" -c "\\copy (select * from public.\"$t\") to '$OUT/csv/$t.csv' csv header"
  n=$(psql "$DB_URL" -Atc "select count(*) from public.\"$t\"")
  echo "$t $n" >> "$OUT/row_counts.txt"
done
echo "backup_date_utc=$STAMP" > "$OUT/README.txt"
echo "Contents: database_public.dump (pg_restore), auth_users_identities.sql, csv/*.csv, row_counts.txt, storage/ (uploaded files, if included)" >> "$OUT/README.txt"
