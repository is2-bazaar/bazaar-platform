#!/usr/bin/env bash
# e2e_json.sh — JSON extraction helpers for the Bazaar E2E suite.
# Depends on: e2e_common.sh

[[ -n "${_E2E_JSON_SOURCED:-}" ]] && return 0
_E2E_JSON_SOURCED=1

# ---------------------------------------------------------------------------
# json_get — extract a value from a JSON file using a dot-path expression
# Supports: .field, .field.subfield, .field[0].subfield, .field | length
# ---------------------------------------------------------------------------
json_get() {
  local file="$1"
  local expr="$2"

  python3 - "$file" "$expr" <<'PY'
import json, re, sys

file_path = sys.argv[1]
expr = sys.argv[2].strip()

try:
    with open(file_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("")
    sys.exit(0)

if expr.startswith("."):
    expr = expr[1:]

def resolve(obj, path):
    cur = obj
    if not path:
        return cur
    for part in path.split("."):
        if not part:
            continue
        m = re.fullmatch(r"([A-Za-z0-9_-]+)(\[(\d+)\])?", part)
        if not m:
            return ""
        key = m.group(1)
        idx = m.group(3)
        if not isinstance(cur, dict) or key not in cur:
            return ""
        cur = cur[key]
        if idx is not None:
            if not isinstance(cur, list):
                return ""
            i = int(idx)
            if i < 0 or i >= len(cur):
                return ""
            cur = cur[i]
    return cur

if expr.endswith(" | length"):
    base = expr[:-9].strip()
    if base.startswith("."):
        base = base[1:]
    value = resolve(data, base)
    try:
        print(len(value))
    except Exception:
        print("")
    sys.exit(0)

value = resolve(data, expr)
if value is None:
    print("")
elif isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, (dict, list)):
    print(json.dumps(value, ensure_ascii=False))
else:
    print(value)
PY
}

# ---------------------------------------------------------------------------
# token_user_id — decode JWT and extract user_id/id/sub claim
# ---------------------------------------------------------------------------
token_user_id() {
  local token="$1"

  python3 - "$token" <<'PY'
import base64, json, sys

token = sys.argv[1]
try:
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    claims = json.loads(base64.urlsafe_b64decode(payload.encode()).decode())
except Exception:
    print("")
    sys.exit(0)

for key in ("user_id", "id", "sub"):
    value = claims.get(key)
    if value is None:
        continue
    value = str(value)
    if value.isdigit():
        print(value)
        sys.exit(0)

print("")
PY
}

# ---------------------------------------------------------------------------
# json_find_product_id_by_name — scan a catalog/list response for a product by name
# ---------------------------------------------------------------------------
json_find_product_id_by_name() {
  local file="$1"
  local target="$2"

  python3 - "$file" "$target" <<'PY'
import json, sys

file_path = sys.argv[1]
target = sys.argv[2]

try:
    with open(file_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("")
    sys.exit(0)

lists = []
if isinstance(data, list):
    lists.append(data)
if isinstance(data, dict):
    for key in ("products", "items", "data"):
        value = data.get(key)
        if isinstance(value, list):
            lists.append(value)
        elif isinstance(value, dict):
            for k2 in ("products", "items", "data"):
                if isinstance(value.get(k2), list):
                    lists.append(value[k2])

for arr in lists:
    for p in arr:
        if isinstance(p, dict) and p.get("name") == target:
            print(p.get("id") or p.get("ID") or "")
            sys.exit(0)

print("")
PY
}

# ---------------------------------------------------------------------------
# json_find_seller_name_by_product_id — find seller_name for a product in a list/detail response
# ---------------------------------------------------------------------------
json_find_seller_name_by_product_id() {
  local file="$1"
  local product_id="$2"

  python3 - "$file" "$product_id" <<'PY'
import json, sys

file_path = sys.argv[1]
product_id = str(sys.argv[2])

try:
    with open(file_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("")
    sys.exit(0)

products = []

def collect(obj):
    if isinstance(obj, dict):
        if isinstance(obj.get("products"), list):
            products.extend(obj["products"])
        if isinstance(obj.get("data"), dict):
            collect(obj["data"])
        # handle single product detail: top-level dict with "id"
        if "id" in obj and ("name" in obj or "seller_name" in obj):
            products.append(obj)
    elif isinstance(obj, list):
        products.extend(obj)

collect(data)

for p in products:
    if not isinstance(p, dict):
        continue
    pid = p.get("id") or p.get("ID")
    if str(pid) == product_id:
        sn = p.get("seller_name") or p.get("sellerName") or ""
        print(sn if sn is not None else "")
        sys.exit(0)

print("")
PY
}

# ---------------------------------------------------------------------------
# json_find_cart_quantity_by_product_id — find quantity of a product in a cart response
# ---------------------------------------------------------------------------
json_find_cart_quantity_by_product_id() {
  local file="$1"
  local product_id="$2"

  python3 - "$file" "$product_id" <<'PY'
import json, sys

file_path = sys.argv[1]
product_id = str(sys.argv[2])

try:
    with open(file_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("0")
    sys.exit(0)

candidates = []

def collect(obj):
    if isinstance(obj, dict):
        if isinstance(obj.get("items"), list):
            candidates.extend(obj["items"])
        if isinstance(obj.get("cart"), dict):
            collect(obj["cart"])
        if isinstance(obj.get("data"), dict):
            collect(obj["data"])
    elif isinstance(obj, list):
        candidates.extend(obj)

collect(data)

for item in candidates:
    if not isinstance(item, dict):
        continue
    pid = item.get("product_id")
    if pid is None:
        pid = item.get("ProductID")
    if str(pid) == product_id:
        qty = item.get("quantity")
        if qty is None:
            qty = item.get("Quantity")
        print(qty if qty is not None else "0")
        sys.exit(0)

print("0")
PY
}

# ---------------------------------------------------------------------------
# new_uuid — generate a random UUIDv4
# ---------------------------------------------------------------------------
new_uuid() {
  python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
}

# ---------------------------------------------------------------------------
# json_find_order_id_by_seller_id — find the order_id for an order owned by seller_id
# ---------------------------------------------------------------------------
json_find_order_id_by_seller_id() {
  local file="$1"
  local seller_id="$2"

  python3 - "$file" "$seller_id" <<'PY'
import json, sys

file_path = sys.argv[1]
seller_id = int(sys.argv[2])

try:
    with open(file_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("")
    sys.exit(0)

orders = []
if isinstance(data, list):
    orders = data
elif isinstance(data, dict):
    for key in ("orders", "data"):
        val = data.get(key)
        if isinstance(val, list):
            orders = val
            break
    if not orders and isinstance(data.get("data"), dict):
        val2 = data["data"].get("orders")
        if isinstance(val2, list):
            orders = val2

for o in orders:
    if not isinstance(o, dict):
        continue
    sid = o.get("seller_id") or o.get("sellerID") or o.get("SellerID")
    if str(sid) == str(seller_id):
        oid = o.get("order_id") or o.get("id") or o.get("ID")
        if oid:
            print(oid)
            sys.exit(0)

print("")
PY
}

# ---------------------------------------------------------------------------
# json_count_orders_for_seller — count orders owned by seller_id in a list
# ---------------------------------------------------------------------------
json_count_orders_for_seller() {
  local file="$1"
  local seller_id="$2"

  python3 - "$file" "$seller_id" <<'PY'
import json, sys

file_path = sys.argv[1]
seller_id = int(sys.argv[2])

try:
    with open(file_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("0")
    sys.exit(0)

orders = []
if isinstance(data, list):
    orders = data
elif isinstance(data, dict):
    for key in ("orders", "data"):
        val = data.get(key)
        if isinstance(val, list):
            orders = val
            break
    if not orders and isinstance(data.get("data"), dict):
        val2 = data["data"].get("orders")
        if isinstance(val2, list):
            orders = val2

count = 0
for o in orders:
    if not isinstance(o, dict):
        continue
    sid = o.get("seller_id") or o.get("sellerID") or o.get("SellerID")
    if str(sid) == str(seller_id):
        count += 1

print(count)
PY
}

# ---------------------------------------------------------------------------
# json_orders_all_have_seller — check ALL orders in list belong to seller_id
# ---------------------------------------------------------------------------
json_orders_all_have_seller() {
  local file="$1"
  local seller_id="$2"

  python3 - "$file" "$seller_id" <<'PY'
import json, sys

file_path = sys.argv[1]
seller_id = int(sys.argv[2])

try:
    with open(file_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("false")
    sys.exit(0)

orders = []
if isinstance(data, list):
    orders = data
elif isinstance(data, dict):
    for key in ("orders", "data"):
        val = data.get(key)
        if isinstance(val, list):
            orders = val
            break
    if not orders and isinstance(data.get("data"), dict):
        val2 = data["data"].get("orders")
        if isinstance(val2, list):
            orders = val2

if not orders:
    print("false")
    sys.exit(0)

for o in orders:
    if not isinstance(o, dict):
        continue
    sid = o.get("seller_id") or o.get("sellerID") or o.get("SellerID")
    if str(sid) != str(seller_id):
        print("false")
        sys.exit(0)

print("true")
PY
}

# ---------------------------------------------------------------------------
# json_order_items_all_have_seller — check ALL items across ALL orders belong to seller_id
# ---------------------------------------------------------------------------
json_order_items_all_have_seller() {
  local file="$1"
  local seller_id="$2"

  python3 - "$file" "$seller_id" <<'PY'
import json, sys

file_path = sys.argv[1]
seller_id = int(sys.argv[2])

try:
    with open(file_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("false")
    sys.exit(0)

orders = []
if isinstance(data, list):
    orders = data
elif isinstance(data, dict):
    if isinstance(data.get("items"), list):
        orders = [data]
    else:
        for key in ("orders", "data"):
            val = data.get(key)
            if isinstance(val, list):
                orders = val
                break
        if not orders and isinstance(data.get("data"), dict):
            wrapped = data["data"]
            if isinstance(wrapped.get("items"), list):
                orders = [wrapped]
            else:
                val2 = wrapped.get("orders")
                if isinstance(val2, list):
                    orders = val2

if not orders:
    print("false")
    sys.exit(0)

for o in orders:
    if not isinstance(o, dict):
        print("false")
        sys.exit(0)
    items = o.get("items")
    if not isinstance(items, list):
        print("false")
        sys.exit(0)
    for item in items:
        if not isinstance(item, dict):
            continue
        sid = item.get("seller_id") or item.get("sellerID") or item.get("SellerID")
        if sid is None:
            print("false")
            sys.exit(0)
        if str(sid) != str(seller_id):
            print("false")
            sys.exit(0)

print("true")
PY
}

# ---------------------------------------------------------------------------
# json_order_has_foreign_seller_items — check if a single-order detail has items from other sellers
# ---------------------------------------------------------------------------
json_order_has_foreign_seller_items() {
  local file="$1"
  local seller_id="$2"

  python3 - "$file" "$seller_id" <<'PY'
import json, sys

file_path = sys.argv[1]
seller_id = int(sys.argv[2])

try:
    with open(file_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("false")
    sys.exit(0)

items = []
if isinstance(data, dict):
    items = data.get("items") or []
    if not items and isinstance(data.get("data"), dict):
        items = data["data"].get("items") or []

for item in items:
    if not isinstance(item, dict):
        continue
    sid = item.get("seller_id") or item.get("sellerID") or item.get("SellerID")
    if sid is None:
        print("true")
        sys.exit(0)
    if str(sid) != str(seller_id):
        print("true")
        sys.exit(0)

print("false")
PY
}

# ---------------------------------------------------------------------------
# json_order_status — extract the status field from an order response
# ---------------------------------------------------------------------------
json_order_status() {
  local file="$1"

  python3 - "$file" <<'PY'
import json, sys

file_path = sys.argv[1]

try:
    with open(file_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("")
    sys.exit(0)

if isinstance(data, dict):
    if "status" in data:
        print(data["status"])
        sys.exit(0)
    wrapped = data.get("data")
    if isinstance(wrapped, dict) and "status" in wrapped:
        print(wrapped["status"])
        sys.exit(0)
    orders = data.get("orders")
    if isinstance(orders, list) and orders and isinstance(orders[0], dict) and "status" in orders[0]:
        print(orders[0]["status"])
        sys.exit(0)

print("")
PY
}

# ---------------------------------------------------------------------------
# NEW helpers — added by refactor
# ---------------------------------------------------------------------------

# json_array_length — return the count of elements at a JSON path
json_array_length() {
  local file="$1"
  local path="$2"
  json_get "$file" ".$path | length"
}

# json_field_exists — check if a top-level or nested field exists in the JSON file
json_field_exists() {
  local file="$1"
  local field="$2"

  python3 - "$file" "$field" <<'PY'
import json, sys
file_path = sys.argv[1]
field = sys.argv[2]
try:
    with open(file_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("false")
    sys.exit(0)

def deep_has(obj, key):
    if isinstance(obj, dict):
        if key in obj:
            return True
        for v in obj.values():
            if deep_has(v, key):
                return True
    elif isinstance(obj, list):
        for item in obj:
            if deep_has(item, key):
                return True
    return False

print("true" if deep_has(data, field) else "false")
PY
}

# json_find_order_by_id — find order in a list by order_id/id
json_find_order_by_id() {
  local file="$1"
  local order_id="$2"

  python3 - "$file" "$order_id" <<'PY'
import json, sys
file_path = sys.argv[1]
target = sys.argv[2]

try:
    with open(file_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("false")
    sys.exit(0)

orders = []
if isinstance(data, list):
    orders = data
elif isinstance(data, dict):
    for key in ("orders", "data"):
        val = data.get(key)
        if isinstance(val, list):
            orders = val
            break

for o in orders:
    if not isinstance(o, dict):
        continue
    oid = o.get("order_id") or o.get("id") or o.get("ID")
    if str(oid) == str(target):
        print("true")
        sys.exit(0)

print("false")
PY
}

# json_order_tracking_code — extract tracking_code from order detail
json_order_tracking_code() {
  local file="$1"

  python3 - "$file" <<'PY'
import json, sys
file_path = sys.argv[1]
try:
    with open(file_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("")
    sys.exit(0)

def resolve(obj):
    if isinstance(obj, dict):
        if "tracking_code" in obj:
            return obj["tracking_code"]
        for key in ("order", "data"):
            val = obj.get(key)
            if isinstance(val, dict):
                return resolve(val)
    return ""

result = resolve(data)
print(result if result else "")
PY
}

# json_count_history_status — count history entries with a given status
json_count_history_status() {
  local file="$1"
  local target_status="$2"

  python3 - "$file" "$target_status" <<'PY'
import json, sys
file_path = sys.argv[1]
target_status = sys.argv[2]

try:
    with open(file_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("0")
    sys.exit(0)

def collect_history(obj):
    if isinstance(obj, dict):
        if isinstance(obj.get("history"), list):
            return obj["history"]
        if isinstance(obj.get("data"), dict):
            return collect_history(obj["data"])
    return []

entries = collect_history(data)
count = sum(1 for e in entries if isinstance(e, dict) and e.get("status") == target_status)
print(count)
PY
}

# ---------------------------------------------------------------------------
# json_find_buyer_name_by_order_id — find buyer_name (or buyer_username) for
# an order in a list or single-order detail response.
# Falls back to buyer_email if present.
# ---------------------------------------------------------------------------
json_find_buyer_name_by_order_id() {
  local file="$1"
  local order_id="$2"

  python3 - "$file" "$order_id" <<'PY'
import json, sys

file_path = sys.argv[1]
target = str(sys.argv[2])

try:
    with open(file_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("")
    sys.exit(0)

# Collect candidate order objects
candidates = []

def collect(obj):
    if isinstance(obj, dict):
        # Single order detail (has "id" and "seller_id" or "buyer_id")
        if "id" in obj and ("seller_id" in obj or "buyer_id" in obj):
            candidates.append(obj)
        # List wrapper: "orders" or "data.orders"
        for key in ("orders", "data"):
            val = obj.get(key)
            if isinstance(val, list):
                for o in val:
                    if isinstance(o, dict):
                        candidates.append(o)
            elif isinstance(val, dict):
                collect(val)
    elif isinstance(obj, list):
        for o in obj:
            if isinstance(o, dict):
                candidates.append(o)

collect(data)

for o in candidates:
    if not isinstance(o, dict):
        continue
    oid = o.get("id") or o.get("ID") or o.get("order_id")
    if str(oid) == target:
        # Prefer buyer_name, fallback to buyer_username, then buyer_email
        bn = o.get("buyer_name")
        if bn is not None:
            print(bn if bn != "" else "")
            sys.exit(0)
        bu = o.get("buyer_username")
        if bu is not None:
            print(bu if bu != "" else "")
            sys.exit(0)
        be = o.get("buyer_email")
        if be is not None:
            print(be if be != "" else "")
            sys.exit(0)
        print("")
        sys.exit(0)

print("")
PY
}
