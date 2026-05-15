#!/usr/bin/env bash
set -euo pipefail

PROJECT="bazaar"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
DBML_DIR="$ROOT_DIR/docs/db_diagrams/dbml"

if [[ ! -d "$DBML_DIR" ]]; then
  echo "Error: DBML directory not found: $DBML_DIR" >&2
  exit 1
fi

mapfile -t dbml_files < <(find "$DBML_DIR" -maxdepth 1 -name '*.dbml' -print0 | sort -z | xargs -0 -n1 basename -a 2>/dev/null || true)

if [[ ${#dbml_files[@]} -eq 0 ]]; then
  echo "Error: No .dbml files found in $DBML_DIR" >&2
  exit 1
fi

TMP_FILE="$(mktemp).dbml"

echo "Generating global DBML..."

cat <<EOF >"$TMP_FILE"
Project bazaar_microservices {
  database_type: "PostgreSQL"
}

EOF

for basename_file in "${dbml_files[@]}"; do
  file="$DBML_DIR/$basename_file"
  echo "// ====================================" >>"$TMP_FILE"
  echo "// $basename_file" >>"$TMP_FILE"
  echo "// ====================================" >>"$TMP_FILE"

  sed '/^Project /,/^}/d' "$file" >>"$TMP_FILE"

  echo "" >>"$TMP_FILE"
done

echo "Publishing to DBDocs..."

npx dbdocs build "$TMP_FILE" --project="$PROJECT"

rm -f "$TMP_FILE"

echo "Done."
