#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Bazaar — Seed Render Products
#
# Inserts up to 50 demo products directly into the Render/Neon catalog database
# via psql. Designed for frontend E2E demos and manual QA.
#
# Safety:
#   - Requires CONFIRMATION="CONFIRMO POBLAR PRODUCTOS RENDER" (unless DRY_RUN)
#   - Auto-loads DB URLs from scripts/maintenance/.env.cleanup
#   - Never prints secrets or full DB URLs
#   - Idempotent by product name (safe to re-run with same batch)
#   - Logs everything to tmp/render-product-seed-<ts>/
#
# Usage:
#
#   # Seed 50 products (auto-detect seller):
#   CONFIRMATION="CONFIRMO POBLAR PRODUCTOS RENDER" \
#     ./scripts/maintenance/seed_render_products.sh
#
#   # Seed with specific seller and custom batch:
#   CONFIRMATION="CONFIRMO POBLAR PRODUCTOS RENDER" \
#     SEED_SELLER_ID=42 \
#     RENDER_SEED_BATCH_ID=demo-may-2026 \
#     ./scripts/maintenance/seed_render_products.sh
#
#   # Dry-run (preview SQL, no insert):
#   DRY_RUN=true ./scripts/maintenance/seed_render_products.sh
#
# Environment variables:
#   CATALOG_DB_URL         (auto-loaded from .env.cleanup or export)
#   SEED_SELLER_ID         Seller to own the products (auto-detected if unset)
#   RENDER_SEED_BATCH_ID   Batch identifier (default: render-seed-<unix-timestamp>)
#   SEED_PRODUCTS_COUNT    Number of products (default: 50, max: 50)
#   CONFIRMATION           Must be "CONFIRMO POBLAR PRODUCTOS RENDER"
#   DRY_RUN                If "true", generate SQL and preview only
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/seed_products_common.sh"

main() {
  # ── Confirmation gate ───────────────────────────────────────────────────────
  # DRY_RUN bypasses confirmation requirement

  DRY_RUN="${DRY_RUN:-false}"
  if [[ "$DRY_RUN" != "true" ]]; then
    require_seed_confirmation
  fi

  # ── Validate environment ────────────────────────────────────────────────────

  check_psql
  require_catalog_url

  # ── Configuration ───────────────────────────────────────────────────────────

  local batch_id="${RENDER_SEED_BATCH_ID:-render-seed-$(date +%s)}"
  local product_count="${SEED_PRODUCTS_COUNT:-50}"
  local seller_id
  seller_id="$(resolve_seller_id)"
  local run_dir="${RUN_DIR:-$(init_seed_run_dir "seed-${batch_id}")}"
  mkdir -p "$run_dir"/{logs,backup,reports}

  log_info "Batch ID:   $batch_id"
  log_info "Run dir:    $run_dir"
  log_info "Count:      $product_count"
  log_info "Seller ID:  [set]"
  log_info "Dry run:    $DRY_RUN"

  # ── Product definitions ────────────────────────────────────────────────────
  #
  # Format per line:  suffix|description|price|category|stock
  #
  # suffix:   appended to "RENDER_SEED_PRODUCT_<batch>_NNN - "
  # category: technology | entertainment | clothes | furniture
  # price:    in decimal (e.g. 12999.99)
  # stock:    integer 5-50
  #
  # 50 products, realistically distributed across the 4 valid categories.

  local product_data=(
    # === technology (15 products) ===
    "Auriculares Bluetooth|Auriculares inalámbricos con cancelación de ruido activa y 30h de batería|24999.99|technology|20"
    "Teclado Mecánico RGB|Teclado mecánico switches Cherry MX Red, retroiluminación personalizable|18999.50|technology|12"
    "Mouse Inalámbrico|Mouse ergonómico 8000 DPI, recargable USB-C|8999.00|technology|25"
    "Monitor 27 4K|Monitor IPS 4K UHD, 144Hz, HDR10, FreeSync|149999.99|technology|5"
    "Webcam HD 1080p|Cámara web con micrófono integrado, autoenfoque|12999.00|technology|18"
    "Hub USB-C 7 en 1|Adaptador multipuerto HDMI, USB-A, SD, PD 100W|7999.99|technology|22"
    "Cable HDMI 2.1|Cable HDMI Ultra High Speed 2m, 48Gbps|2999.00|technology|30"
    "Soporte para Notebook|Soporte ajustable de aluminio, ventilación integrada|10999.00|technology|15"
    "SSD Externo 1TB|SSD portátil USB-C, lectura 1050MB/s|32999.99|technology|10"
    "Micrófono Condensador|Micrófono cardioide para streaming, brazo incluido|15999.00|technology|8"
    "Parlante Bluetooth|Parlante portátil resistente al agua IPX7, 20W|17999.00|technology|14"
    "Cargador Rápido 65W|Cargador GaN USB-C + USB-A, compacto|9999.00|technology|28"
    "Protector de Pantalla|Protector vidrio templado para smartphones, antihuellas|1499.00|technology|50"
    "Mousepad XXL|Alfombrilla gaming 900x400mm, superficie suave|4999.00|technology|20"
    "Memoria RAM 16GB|DDR4 3200MHz, CL16, disipador integrado|21999.00|technology|7"
    # === entertainment (12 products) ===
    "Juego de Mesa Estrategia|Juego de mesa cooperativo, 2-6 jugadores, 90min de partida|12999.00|entertainment|10"
    "Rompecabezas 1000 piezas|Rompecabezas paisaje nocturno, 1000 piezas|5499.00|entertainment|16"
    "Mazo de Cartas Premium|Mazo de naipes 100% plástico, waterproof|2499.00|entertainment|35"
    "Set de Ajedrez|Ajedrez magnético plegable, piezas de madera|8999.00|entertainment|9"
    "Control Inalámbrico|Gamepad Bluetooth, compatible PC/Switch/Mobile|13999.00|entertainment|13"
    "Guitarra Criolla|Guitarra acústica de estudio, tapa de cedro|45999.00|entertainment|4"
    "Cuerdas de Guitarra|Set de 6 cuerdas nylon, tensión media|1499.00|entertainment|40"
    "Pelota de Fútbol|Pelota profesional cosida a mano, tamaño 5|10999.00|entertainment|11"
    "Mat de Yoga|Mat antideslizante 6mm, 183x61cm, correa incluida|6999.00|entertainment|19"
    "Batería Electrónica|Batería digital compacta, 200 sonidos, auriculares|67999.00|entertainment|3"
    "Caña de Pescar|Caña telescópica 2.4m, fibra de carbono, reel incluido|15999.00|entertainment|7"
    "Raqueta de Tenis|Raqueta graphite, 280g, grip antideslizante|24999.00|entertainment|6"
    # === clothes (12 products) ===
    "Remera Algodón|Remera 100% algodón peinado, cuello redondo|3499.00|clothes|40"
    "Jean Clásico|Jean recto denim 12oz, cinco bolsillos|9999.00|clothes|20"
    "Buzo Canguro|Buzo con capucha, algodón felpado, bolsillo frontal|12999.00|clothes|15"
    "Campera Impermeable|Campera cortaviento con membrana impermeable|24999.00|clothes|10"
    "Zapatillas Urbanas|Zapatillas lifestyle, suela vulcanizada|18999.00|clothes|12"
    "Vestido Estampado|Vestido midi, algodón liviano, cintura ajustable|11999.00|clothes|8"
    "Bufanda de Lana|Bufanda tejida, lana merino, 180x25cm|5999.00|clothes|25"
    "Gorra Deportiva|Gorra ajustable, visera curva, transpirable|3499.00|clothes|30"
    "Pack Medias|Pack x6 medias algodón, caña media, colores surtidos|2999.00|clothes|35"
    "Cinturón Cuero|Cinturón cuero vacuno, hebilla metálica, 3.5cm|7999.00|clothes|18"
    "Mochila 25L|Mochila urbana, compartimento laptop 15 pulgadas, impermeable|14999.00|clothes|14"
    "Billetera Minimalista|Billetera RFID blocking, cuero sintético, 8 slots|3999.00|clothes|28"
    # === furniture (11 products) ===
    "Escritorio Compacto|Escritorio 120x60cm, melamina blanca, patas metálicas|34999.00|furniture|5"
    "Silla Ergonómica|Silla de oficina, soporte lumbar ajustable, respaldo mesh|89999.00|furniture|3"
    "Biblioteca Modular|Estantería 5 niveles, 180x80x30cm, melamina|42999.00|furniture|4"
    "Lámpara de Pie|Lámpara LED regulable, 3 temperaturas de color, 150cm|19999.00|furniture|7"
    "Alfombra 150x200|Alfombra tejida geométrica, pelo corto, antideslizante|24999.00|furniture|6"
    "Espejo Decorativo|Espejo redondo 60cm, marco de madera, para colgar|12999.00|furniture|9"
    "Maceta Cerámica|Maceta esmaltada 25cm, drenaje incluido, varios colores|4499.00|furniture|22"
    "Reloj de Pared|Reloj analógico silencioso, 30cm, diseño minimalista|6999.00|furniture|11"
    "Cojín Decorativo|Cojín 45x45cm, funda removible, relleno incluido|2999.00|furniture|30"
    "Mesa Auxiliar|Mesa ratona 50cm, metal y vidrio templado|17999.00|furniture|8"
    "Caja Organizadora|Caja modular 30L, plástico reforzado, apilable|5499.00|furniture|16"
  )

  # ── Generate SQL ────────────────────────────────────────────────────────────

  local sql_file="$run_dir/seed_products.sql"
  local report_file="$run_dir/reports/seed_report.md"
  local generated=0

  log_step "Generating SQL: $sql_file"

  {
    echo "-- Bazaar Render Seed Products"
    echo "-- Batch:   $batch_id"
    echo "-- Seller:  $seller_id"
    echo "-- Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo ""
    echo "BEGIN;"
    echo ""

    local index=1
    local suffix desc price category stock
    local full_name escaped_name escaped_desc image_url padded

    for line in "${product_data[@]}"; do
      # Skip empty or comment lines
      [[ -z "$line" ]] && continue
      [[ "$line" == \#* ]] && continue
      # Respect product count limit
      [[ $index -gt $product_count ]] && break

      IFS='|' read -r suffix desc price category stock <<<"$line"

      # Build full name: RENDER_SEED_PRODUCT_<batch>_NNN - <suffix>
      printf -v padded '%03d' "$index"
      full_name="RENDER_SEED_PRODUCT_${batch_id}_${padded} - ${suffix}"

      # Description includes batch reference for targeted cleanup
      escaped_desc="$(sql_escape "Render seed product generated by maintenance script | batch=${batch_id} | ${desc}")"
      escaped_name="$(sql_escape "$full_name")"

      # Image placeholder URL
      image_url="https://placehold.co/600x400?text=Bazaar+Product+${padded}"

      cat <<SQL
-- Product $padded: $suffix
INSERT INTO products (seller_id, name, description, price, stock_quantity, image_bucket_url, category, status)
SELECT ${seller_id}, '${escaped_name}', '${escaped_desc}', ${price}, ${stock}, '${image_url}', '${category}', 'active'
WHERE NOT EXISTS (SELECT 1 FROM products WHERE name = '${escaped_name}');

SQL

      ((index++)) || true
      ((generated++)) || true
    done

    echo ""
    echo "COMMIT;"
  } >"$sql_file"

  log_info "Generated SQL for $generated products."
  log_info "SQL file: $sql_file"

  # ── Dry-run preview ─────────────────────────────────────────────────────────

  if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    blue "==== DRY RUN ===="
    echo ""
    echo "SQL file generated at: $sql_file"
    echo "Run directory:        $run_dir"
    echo ""
    echo "Preview (first 5 INSERTs):"
    echo "─────────────────────────────"
    grep "^INSERT" "$sql_file" | head -5 || true
    echo "  ... ($generated total)"
    echo ""
    blue "No data was inserted (DRY_RUN=true)."
    echo ""
    echo "To actually insert:"
    echo "  CONFIRMATION=\"CONFIRMO POBLAR PRODUCTOS RENDER\" \\"
    echo "    RENDER_SEED_BATCH_ID=$batch_id \\"
    echo "    ./scripts/maintenance/seed_render_products.sh"
    exit 0
  fi

  # ── Execute seed ────────────────────────────────────────────────────────────

  seed_banner

  local log_file="$run_dir/logs/seed_psql.log"
  log_step "Executing seed SQL against Render catalog DB..."

  if psql "$CATALOG_DB_URL" -f "$sql_file" -o "$log_file" 2>&1; then
    log_info "psql execution completed."
  else
    red "[seed][error]  psql execution failed. Check log: $log_file"
    log_info "The transaction should have been rolled back automatically."
    exit 1
  fi

  # ── Count results ───────────────────────────────────────────────────────────

  log_step "Counting inserted products..."
  local total_in_db where_clause
  where_clause="$(build_seed_product_where "$batch_id")"
  total_in_db="$(psql "$CATALOG_DB_URL" -t -A -c \
    "SELECT COUNT(*) FROM products WHERE $where_clause;")"
  total_in_db="${total_in_db//[[:space:]]/}"
  total_in_db="${total_in_db:-0}"

  # Write report
  {
    echo "# Render Seed Products — Report"
    echo ""
    echo "- **Timestamp**: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "- **Batch ID**: \`$batch_id\`"
    echo "- **Seller ID**: \`$seller_id\`"
    echo "- **Run directory**: \`$run_dir\`"
    echo ""
    echo "## Results"
    echo ""
    echo "| Metric | Value |"
    echo "|--------|-------|"
    echo "| Products generated | $generated |"
    echo "| Products in DB (this batch) | $total_in_db |"
    echo ""
    echo "## Files"
    echo ""
    echo "- SQL: \`$sql_file\`"
    echo "- Log: \`$log_file\`"
    echo ""
    echo "## Cleanup command"
    echo ""
    echo '```bash'
    echo "RENDER_SEED_BATCH_ID=$batch_id \\"
    echo "  CONFIRMATION=\"CONFIRMO BORRAR PRODUCTOS SEED RENDER\" \\"
    echo "  ./scripts/maintenance/delete_render_seed_products.sh"
    echo '```'
  } >"$report_file"

  # ── Summary ─────────────────────────────────────────────────────────────────

  echo ""
  green "==== SEED COMPLETE ===="
  echo ""
  echo "  Batch ID:     $batch_id"
  echo "  Seller ID:    $seller_id"
  echo "  Generated:    $generated products"
  echo "  In DB now:    $total_in_db"
  echo "  Run dir:      $run_dir"
  echo "  Report:       $report_file"
  echo ""
  echo "To delete these products later:"
  echo ""
  echo "  RENDER_SEED_BATCH_ID=$batch_id \\"
  echo "  CONFIRMATION=\"CONFIRMO BORRAR PRODUCTOS SEED RENDER\" \\"
  echo "  ./scripts/maintenance/delete_render_seed_products.sh"
  echo ""
  green "Done."
}

main "$@"
