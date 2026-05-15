#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Bazaar — Seed Render Products
#
# Creates up to 50 demo products via the API gateway. The seller_name is
# automatically filled from the JWT by the catalog service.
#
# Safety:
#   - Requires CONFIRMATION="CONFIRMO POBLAR PRODUCTOS RENDER" (unless DRY_RUN)
#   - Auto-loads RENDER_API_BASE_URL from scripts/maintenance/.env.cleanup
#   - Never prints secrets or full tokens
#   - Idempotent via Idempotency-Key header per product
#   - Logs all HTTP requests/responses to tmp/render-product-seed-<ts>/http/
#
# Usage:
#
#   # Seed 50 products as a specific seller:
#   CONFIRMATION="CONFIRMO POBLAR PRODUCTOS RENDER" \
#     SEED_SELLER_EMAIL="seller@example.com" \
#     SEED_SELLER_PASSWORD="..." \
#     ./scripts/maintenance/seed_render_products.sh
#
#   # Seed with custom batch ID:
#   CONFIRMATION="CONFIRMO POBLAR PRODUCTOS RENDER" \
#     SEED_SELLER_EMAIL="seller@example.com" \
#     SEED_SELLER_PASSWORD="..." \
#     RENDER_SEED_BATCH_ID="demo-may-2026" \
#     ./scripts/maintenance/seed_render_products.sh
#
#   # Dry-run (preview only, no actual API writes):
#   DRY_RUN=true ./scripts/maintenance/seed_render_products.sh
#
# Environment variables:
#   RENDER_API_BASE_URL    Gateway base URL (auto-loaded from .env.cleanup)
#   SEED_SELLER_EMAIL      Seller email for authentication (REQUIRED for non-dry-run)
#   SEED_SELLER_PASSWORD   Seller password (REQUIRED for non-dry-run)
#   RENDER_SEED_BATCH_ID   Batch identifier (default: render-seed-<unix-timestamp>)
#   SEED_PRODUCTS_COUNT    Number of products (default: 50, max: 50)
#   CONFIRMATION           Must be "CONFIRMO POBLAR PRODUCTOS RENDER"
#   DRY_RUN                If "true", preview only — no API writes
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

  check_curl
  require_api_base_url

  # ── Configuration ───────────────────────────────────────────────────────────

  local batch_id="${RENDER_SEED_BATCH_ID:-render-seed-$(date +%s)}"
  local product_count
  product_count="$(validate_seed_products_count "${SEED_PRODUCTS_COUNT:-50}")"
  local run_dir="${RUN_DIR:-$(init_seed_run_dir "seed-${batch_id}")}"
  # If init_seed_run_dir ran in a command substitution (subshell),
  # RUN_DIR and SEED_HTTP_DIR are not visible. Set them explicitly.
  export RUN_DIR="$run_dir"
  export SEED_HTTP_DIR="${SEED_HTTP_DIR:-$run_dir/http}"
  mkdir -p "$run_dir"/{logs,reports} "$SEED_HTTP_DIR"

  log_info "Batch ID:   $batch_id"
  log_info "Run dir:    $run_dir"
  log_info "Count:      $product_count"
  log_info "Dry run:    $DRY_RUN"

  # ── Authenticate seller ────────────────────────────────────────────────────

  if [[ "$DRY_RUN" != "true" ]]; then
    seed_login
    log_info "Seller ID: [set]"
  else
    log_info "Seller credentials: not required for dry-run"
    # For dry-run, we still validate that vars are present for preview
    log_info "SEED_SELLER_EMAIL: ${SEED_SELLER_EMAIL:-<not set>}"
  fi

  # ── Product definitions ────────────────────────────────────────────────────
  #
  # Format per line:  name|human_desc|price|category|stock
  #
  # name:     human-readable product name (displayed in catalog UX)
  # human_desc: human-readable description (shown to buyers)
  # category: technology | entertainment | clothes | furniture
  # price:    in decimal (e.g. 12999.99)
  # stock:    integer 5-50
  #
  # The technical seed marker (RENDER_SEED batch=...) is added automatically
  # to the description field so delete scripts can identify seed products
  # without polluting the UX-visible name.
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

  # ── Preview / Dry-run header ────────────────────────────────────────────────

  local index=1
  local human_name human_desc price category stock
  local full_name padded

  local products_to_create=()
  for line in "${product_data[@]}"; do
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue
    [[ $index -gt $product_count ]] && break

    IFS='|' read -r human_name human_desc price category stock <<<"$line"
    printf -v padded '%03d' "$index"
    full_name="${human_name}"
    products_to_create+=("$full_name")

    ((index++)) || true
  done

  local total_to_create=$((index - 1))
  log_info "Products to create: $total_to_create"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    blue "==== DRY RUN ===="
    echo ""
    echo "Run directory: $run_dir"
    echo "API base URL:  $RENDER_API_BASE_URL"
    echo ""
    echo "Would authenticate as: ${SEED_SELLER_EMAIL:-<not set>}"
    echo "Would create $total_to_create products via POST /catalog/me/products"
    echo ""
    echo "Preview (first 5 products):"
    echo "─────────────────────────────"
    local i=0
    for name in "${products_to_create[@]}"; do
      echo "  $name"
      i=$((i + 1))
      [[ $i -ge 5 ]] && break
    done
    echo "  ... ($total_to_create total)"
    echo ""
    blue "No products were created (DRY_RUN=true)."
    echo ""
    echo "To actually create:"
    echo "  CONFIRMATION=\"CONFIRMO POBLAR PRODUCTOS RENDER\" \\"
    echo "    SEED_SELLER_EMAIL=\"seller@example.com\" \\"
    echo "    SEED_SELLER_PASSWORD=\"...\" \\"
    echo "    RENDER_SEED_BATCH_ID=$batch_id \\"
    echo "    ./scripts/maintenance/seed_render_products.sh"
    exit 0
  fi

  # ── Create products via API ─────────────────────────────────────────────────

  seed_banner

  local created=0
  local failed=0
  local report_file="$run_dir/reports/seed_report.md"
  local log_file="$run_dir/logs/seed_api.log"

  {
    echo "# Bazaar Render Seed Products — API log"
    echo ""
    echo "- **Timestamp**: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "- **Batch ID**: \`$batch_id\`"
    echo "- **Seller email**: \`$SEED_SELLER_EMAIL\`"
    echo "- **Gateway**: \`$RENDER_API_BASE_URL\`"
    echo ""
    echo "## Requests"
    echo ""
  } >"$log_file"

  index=1
  for line in "${product_data[@]}"; do
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue
    [[ $index -gt $product_count ]] && break

    IFS='|' read -r human_name human_desc price category stock <<<"$line"

    printf -v padded '%03d' "$index"
    full_name="${human_name}"

    local description_text="${human_desc} | RENDER_SEED batch=${batch_id}"
    local image_url="https://placehold.co/600x400?text=Bazaar+Product+${padded}"
    local idempotency_key="seed-${batch_id}-${padded}"

    # Build JSON payload using python3 for safe escaping
    local payload
    payload="$(
      python3 - "$full_name" "$description_text" "$price" "$stock" "$image_url" "$category" <<'PY'
import json, sys
name = sys.argv[1]
description = sys.argv[2]
price = float(sys.argv[3])
stock = int(sys.argv[4])
image_url = sys.argv[5]
category = sys.argv[6]
print(json.dumps({
    "name": name,
    "description": description,
    "price": price,
    "stock_quantity": stock,
    "image_bucket_url": image_url,
    "category": category,
    "status": "active"
}))
PY
    )"

    local label="seed-create-${padded}"
    local code
    code="$(seed_api_req "$label" POST "/catalog/me/products" "$payload" "$idempotency_key")"

    if is_2xx "$code"; then
      green "  [$padded/$total_to_create] Created: $human_name  (HTTP $code)"
      {
        echo "- [$padded] \`$full_name\` → HTTP $code ✓"
      } >>"$log_file"
      created=$((created + 1))
    elif [[ "$code" == "409" ]]; then
      red "  [$padded/$total_to_create] CONFLICT: $human_name  (HTTP $code)"
      local err_body
      err_body="$(cat "$SEED_HTTP_DIR/${label}.json" 2>/dev/null | tr '\n' ' ' | head -c 300)"
      {
        echo "- [$padded] \`$full_name\` → HTTP $code CONFLICT ✗  body: ${err_body}"
      } >>"$log_file"
      failed=$((failed + 1))
    else
      red "  [$padded/$total_to_create] FAILED: $human_name  (HTTP $code)"
      local err_body
      err_body="$(cat "$SEED_HTTP_DIR/${label}.json" 2>/dev/null | tr '\n' ' ' | head -c 300)"
      {
        echo "- [$padded] \`$full_name\` → HTTP $code ✗  body: ${err_body}"
      } >>"$log_file"
      failed=$((failed + 1))
    fi

    ((index++)) || true
  done

  # ── Count created products via API list ─────────────────────────────────────

  log_step "Verifying via API list..."
  seed_api_req "seed-list-verify" GET "/catalog/me/products?page=1&page_size=100" >/dev/null

  local list_code
  list_code="$(cat "$SEED_HTTP_DIR/seed-list-verify.code" 2>/dev/null)"
  local total_in_api=0

  if is_2xx "$list_code"; then
    local marker
    marker="$(seed_product_batch_marker "$batch_id")"

    local verify_total_pages
    verify_total_pages="$(seed_json_get "$SEED_HTTP_DIR/seed-list-verify.json" "total_pages")"
    verify_total_pages="${verify_total_pages:-1}"

    if [[ "$verify_total_pages" -gt 1 ]]; then
      seed_fetch_all_products "seed-list-verify" "$verify_total_pages" 100 >/dev/null
    fi

    total_in_api="$(seed_count_products_across_pages "seed-list-verify" "$marker" "$verify_total_pages")"
  fi

  # ── Report ──────────────────────────────────────────────────────────────────

  {
    echo "# Render Seed Products — Report"
    echo ""
    echo "- **Timestamp**: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "- **Batch ID**: \`$batch_id\`"
    echo "- **Seller email**: \`$SEED_SELLER_EMAIL\`"
    echo "- **Gateway**: \`$RENDER_API_BASE_URL\`"
    echo "- **Run directory**: \`$run_dir\`"
    echo ""
    echo "## Results"
    echo ""
    echo "| Metric | Value |"
    echo "|--------|-------|"
    echo "| Products attempted | $total_to_create |"
    echo "| Products created   | $created |"
    echo "| Products failed    | $failed |"
    echo "| Products in API (this batch) | $total_in_api |"
    echo ""
    echo "## Files"
    echo ""
    echo "- API log: \`$log_file\`"
    echo "- HTTP traces: \`$SEED_HTTP_DIR\`"
    echo ""
    echo "## Cleanup command"
    echo ""
    echo '```bash'
    echo "RENDER_SEED_BATCH_ID=$batch_id \\"
    echo "  SEED_SELLER_EMAIL=\"$SEED_SELLER_EMAIL\" \\"
    echo "  SEED_SELLER_PASSWORD=\"...\" \\"
    echo "  CONFIRMATION=\"CONFIRMO BORRAR PRODUCTOS SEED RENDER\" \\"
    echo "  ./scripts/maintenance/delete_render_seed_products.sh"
    echo '```'
  } >"$report_file"

  # ── Summary ─────────────────────────────────────────────────────────────────

  echo ""
  green "==== SEED COMPLETE ===="
  echo ""
  echo "  Batch ID:     $batch_id"
  echo "  Seller email: $SEED_SELLER_EMAIL"
  echo "  Created:      $created of $total_to_create"
  if [[ "$failed" -gt 0 ]]; then
    red "  Failed:       $failed"
  fi
  echo "  In API now:   $total_in_api"
  echo "  Run dir:      $run_dir"
  echo "  Report:       $report_file"
  echo ""

  local had_error=0
  if [[ "$failed" -gt 0 ]]; then
    red "  ERROR: $failed products failed to seed. Check the log and HTTP traces."
    had_error=1
  fi
  if [[ "$total_in_api" -lt "$total_to_create" ]]; then
    red "  ERROR: expected at least $total_to_create products for this batch, found $total_in_api."
    had_error=1
  fi

  echo "To delete these products later:"
  echo ""
  echo "  RENDER_SEED_BATCH_ID=$batch_id \\"
  echo "  SEED_SELLER_EMAIL=\"$SEED_SELLER_EMAIL\" \\"
  echo "  SEED_SELLER_PASSWORD=\"...\" \\"
  echo "  CONFIRMATION=\"CONFIRMO BORRAR PRODUCTOS SEED RENDER\" \\"
  echo "  ./scripts/maintenance/delete_render_seed_products.sh"
  echo ""

  if [[ "$had_error" -eq 1 ]]; then
    exit 1
  fi

  green "Done."
}

main "$@"
