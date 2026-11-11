#!/usr/bin/env bash
# Exercises the REST API. Usage: ./test.sh [base-url]
# Default uses the NodePort on this machine; or pass http://<any-node-ip>:30080
BASE="${1:-http://127.0.0.1:30080}"
pp() { python3 -m json.tool 2>/dev/null || cat; }
hr() { echo; echo "### $*"; }

hr "GET /whoami  (B and A should show DIFFERENT nodes and pod IPs)"
curl -s "$BASE/whoami" | pp
hr "GET /products"
curl -s "$BASE/products" | pp
hr "GET /products?category=furniture"
curl -s "$BASE/products?category=furniture" | pp
hr "GET /products/1"
curl -s "$BASE/products/1" | pp
hr "POST /products"
curl -s -X POST "$BASE/products" -H 'Content-Type: application/json' \
     -d '{"name":"Monitor 27in","category":"electronics","price":199.9,"stock":14}' | pp
hr "GET /products/7  (the new one)"
curl -s "$BASE/products/7" | pp
hr "GET /products/999  (expect 404)"
curl -s -w '\nHTTP %{http_code}\n' "$BASE/products/999"
hr "POST invalid body (expect 422)"
curl -s -w '\nHTTP %{http_code}\n' -X POST "$BASE/products" -H 'Content-Type: application/json' -d '{"name":""}'
hr "DELETE /products/7"
curl -s -X DELETE "$BASE/products/7" | pp
