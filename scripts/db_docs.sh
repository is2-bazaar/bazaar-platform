#!/bin/bash

set -e

PROJECT="bazaar"

# directorio raíz del repo
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# carpeta donde están los dbml
DBML_DIR="$ROOT_DIR/docs/db_diagrams/dbml"

# archivo temporal
TMP_FILE=$(mktemp).dbml

echo "Generating global DBML..."

# encabezado global
cat <<EOF >"$TMP_FILE"
Project bazaar_microservices {
  database_type: "PostgreSQL"
}

EOF

# recorrer todos los dbml
for file in "$DBML_DIR"/*.dbml; do
  echo "// ====================================" >>"$TMP_FILE"
  echo "// $(basename "$file")" >>"$TMP_FILE"
  echo "// ====================================" >>"$TMP_FILE"

  # elimina bloques Project si existen
  sed '/^Project /,/^}/d' "$file" >>"$TMP_FILE"

  echo "" >>"$TMP_FILE"
done

echo "Publishing to DBDocs..."

npx dbdocs build "$TMP_FILE" --project="$PROJECT"

rm "$TMP_FILE"

echo "Done."
