#!/usr/bin/env bash
# End-to-end benchmark: Claude Code + ICM MCP pipeline
# Tests that Claude proactively uses icm_memory_recall and gets correct results
#
# IMPORTANT: Run this from a regular terminal, NOT from inside Claude Code.
# Claude Code cannot be nested (claude -p inside claude session fails).
#
# Usage: ./scripts/bench-claude-e2e.sh
set -euo pipefail

# Unset CLAUDECODE to allow nested invocation
unset CLAUDECODE 2>/dev/null || true

ICM="./target/release/icm"
TMPDIR=$(mktemp -d)
DB="$TMPDIR/bench.db"
RESULTS="$TMPDIR/results.log"
MCP_CONFIG="$TMPDIR/mcp.json"

echo "=== ICM x Claude Code E2E Benchmark ==="
echo "DB: $DB"
echo ""

# --- Seed memories ---
MEMORIES=(
  "decisions-arch|On utilise PostgreSQL pour la persistence et Redis pour le cache session|high|postgres,redis,cache"
  "decisions-arch|L'API REST utilise des versions dans l'URL: /api/v1/, /api/v2/. Jamais de versioning par header|high|api,versioning,rest"
  "errors-resolved|Bug critique: memory leak dans le worker pool quand les connexions WebSocket ne sont pas fermees proprement. Fix: ajouter un timeout de 30s sur les idle connections|critical|memory-leak,websocket,worker"
  "errors-resolved|Le build Docker echoue sur Alpine a cause de musl vs glibc pour les bindings natifs. Solution: utiliser debian-slim comme image de base|high|docker,alpine,musl,glibc"
  "preferences|L'utilisateur veut toujours des reponses en francais et des commits concis sans emoji|medium|french,commits,style"
  "context-project|Le projet ICM est un systeme de memoire persistante pour LLMs ecrit en Rust avec 4 crates: core, store, mcp, cli|high|icm,rust,workspace"
  "decisions-arch|L'authentification se fait par OAuth2 avec PKCE flow pour les clients publics, jamais de implicit flow|high|oauth2,pkce,auth"
  "errors-resolved|Erreur CORS en dev: le frontend sur localhost:3000 ne peut pas appeler l'API sur localhost:8080. Fix: ajouter les headers Access-Control-Allow-Origin dans le middleware|medium|cors,frontend,middleware"
  "context-project|La CI utilise GitHub Actions avec 3 jobs: lint, test, build. Le deploy est fait par ArgoCD sur Kubernetes|high|ci,github-actions,argocd,k8s"
  "decisions-arch|Les migrations de base de donnees utilisent sqlx-migrate, jamais de migration manuelle SQL. Chaque migration est idempotente|high|migrations,sqlx,database"
)

echo "Seeding ${#MEMORIES[@]} memories..."
for entry in "${MEMORIES[@]}"; do
  IFS='|' read -r topic content importance keywords <<< "$entry"
  "$ICM" --db "$DB" store -t "$topic" -c "$content" -i "$importance" -k "$keywords" > /dev/null 2>&1
done

echo "Embedding memories..."
"$ICM" --db "$DB" embed --force 2>/dev/null
echo ""

# --- Create temporary MCP config pointing to bench DB ---
ICM_BIN=$(realpath "$ICM")
cat > "$MCP_CONFIG" << EOF
{
  "mcpServers": {
    "icm": {
      "command": "$ICM_BIN",
      "args": ["--db", "$DB", "serve"]
    }
  }
}
EOF
echo "MCP config: $MCP_CONFIG"

# --- System prompt to force ICM usage ---
SYSTEM_PROMPT="Tu as acces a ICM (Infinite Context Memory) via les outils MCP. \
UTILISE TOUJOURS icm_memory_recall pour chercher dans la memoire AVANT de repondre. \
Reponds de facon concise en incluant les details techniques trouves dans la memoire."

# --- Test queries via claude -p ---
# Each test: prompt | expected_keywords (at least one must appear in output)
TESTS=(
  "Quelle base de donnees on utilise pour la persistence dans le projet ?|PostgreSQL,postgres"
  "On a eu un probleme de memory leak recemment, c'etait quoi la cause et le fix ?|WebSocket,timeout,worker,idle"
  "Comment on fait le versioning de l'API ?|/api/v1,URL,header"
  "Le build Docker marche pas sur Alpine, pourquoi ?|musl,glibc,debian-slim"
  "C'est quoi le flow d'authentification qu'on utilise ?|OAuth2,PKCE,implicit"
  "Comment fonctionne la CI du projet ?|GitHub Actions,ArgoCD,lint,test"
  "Comment on gere les migrations de base de donnees ?|sqlx,idempotente,migration"
  "Il y avait un probleme CORS en dev, c'etait quoi ?|localhost,3000,8080,Access-Control"
)

TOTAL=${#TESTS[@]}
PASS=0
FAIL=0
RECALL_USED=0
TOTAL_TIME=0

echo ""
echo "Running $TOTAL queries through Claude Code (claude -p)..."
echo "This may take a few minutes."
echo ""
printf "%-4s  %-60s  %8s  %6s  %s\n" "#" "Query" "Result" "Time" "Details"
printf "%-4s  %-60s  %8s  %6s  %s\n" "---" "$(printf '%0.s-' {1..60})" "------" "-----" "-------"

i=0
for entry in "${TESTS[@]}"; do
  i=$((i + 1))
  IFS='|' read -r prompt expected_kw <<< "$entry"

  start_time=$(date +%s)

  # Run claude with temporary MCP config pointing to bench DB
  response=$(claude -p \
    --mcp-config "$MCP_CONFIG" \
    --allowedTools "mcp__icm__icm_memory_recall,mcp__icm__icm_memory_store" \
    -s "$SYSTEM_PROMPT" \
    "$prompt" 2>"$TMPDIR/stderr_$i.log" || echo "ERROR: $(cat "$TMPDIR/stderr_$i.log")")

  end_time=$(date +%s)
  elapsed=$((end_time - start_time))
  TOTAL_TIME=$((TOTAL_TIME + elapsed))

  # Check if expected keywords appear in response
  hit=0
  IFS=',' read -ra kws <<< "$expected_kw"
  matched_kw=""
  for kw in "${kws[@]}"; do
    if echo "$response" | grep -qi "$kw"; then
      hit=1
      matched_kw="$kw"
      break
    fi
  done

  # Check if response mentions recall/memory usage
  used_recall=0
  if echo "$response" | grep -qiE "recall|memoire|memory|icm"; then
    used_recall=1
    RECALL_USED=$((RECALL_USED + 1))
  fi

  if [ "$hit" -eq 1 ]; then
    PASS=$((PASS + 1))
    result="HIT"
  else
    FAIL=$((FAIL + 1))
    result="MISS"
  fi

  display_q="${prompt:0:58}"
  printf "%-4s  %-60s  %8s  %4ds  %s\n" "$i" "$display_q" "$result" "$elapsed" "$matched_kw"

  # Log full response for debugging
  {
    echo "=== Query $i: $prompt ==="
    echo "--- Response ---"
    echo "$response"
    echo "--- Stderr ---"
    cat "$TMPDIR/stderr_$i.log" 2>/dev/null || true
    echo ""
  } >> "$RESULTS"
done

echo ""
echo "================================================================"
echo "  Results:        $PASS/$TOTAL correct ($((PASS * 100 / TOTAL))%)"
echo "  ICM recall:     $RECALL_USED/$TOTAL"
echo "  Failures:       $FAIL"
echo "  Total time:     ${TOTAL_TIME}s (avg $((TOTAL_TIME / TOTAL))s/query)"
echo "  Full responses: $RESULTS"
echo "================================================================"

echo ""
echo "Inspect responses: cat $RESULTS"
