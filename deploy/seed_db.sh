#!/bin/bash
# =============================================================================
# seed_db.sh — Database Seeding Script for inQuran
#
# Runs ON the remote VPS (called via SSH from release.sh).
#
# Modes:
#   Default (FULL_RESEED=false):
#     Tracks applied migrations in _migration_history table.
#     Only applies NEW migration files. Safe for production.
#
#   Full Reseed (FULL_RESEED=true):
#     Drops public schema, re-applies ALL migrations, then re-seeds all data.
#     Use for staging resets or when migrations change existing table structure.
#
# Usage:
#   bash seed_db.sh                     # idempotent mode
#   FULL_RESEED=true bash seed_db.sh    # full wipe + reseed
# =============================================================================
set -euo pipefail

APP_DIR="$HOME/inquran-app"
SUPABASE_DOCKER_DIR="$HOME/supabase/docker"
MIGRATIONS_DIR="$APP_DIR/supabase/migrations"
FULL_RESEED="${FULL_RESEED:-false}"

log()  { echo "  [seed_db] $*"; }
ok()   { echo "  [seed_db] ✅ $*"; }
fail() { echo "  [seed_db] ❌ $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Load Supabase credentials from its own .env
# ---------------------------------------------------------------------------
if [ ! -f "$SUPABASE_DOCKER_DIR/.env" ]; then
    fail "Supabase .env not found at $SUPABASE_DOCKER_DIR/.env — is Supabase running?"
fi

POSTGRES_PASS=$(grep "^POSTGRES_PASSWORD=" "$SUPABASE_DOCKER_DIR/.env" | cut -d= -f2)
SERVICE_KEY=$(grep "^SERVICE_ROLE_KEY=" "$SUPABASE_DOCKER_DIR/.env" | cut -d= -f2)

export PUBLIC_SUPABASE_URL="http://127.0.0.1:8000"
export DATABASE_URL="postgresql://postgres:${POSTGRES_PASS}@127.0.0.1:5432/postgres"
export SUPABASE_SERVICE_ROLE_KEY="$SERVICE_KEY"

log "Using Supabase at $PUBLIC_SUPABASE_URL"

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------
run_sql() {
    docker exec supabase-db psql -U postgres -d postgres -c "$1" -q
}
run_sql_file() {
    docker exec -i supabase-db psql -U postgres -d postgres -f - < "$1"
}
run_sql_scalar() {
    docker exec supabase-db psql -U postgres -d postgres -t -c "$1" | tr -d '[:space:]'
}

# ---------------------------------------------------------------------------
# Wait for DB to be ready
# ---------------------------------------------------------------------------
log "Waiting for Postgres to be ready..."
for i in $(seq 1 30); do
    if docker exec supabase-db pg_isready -U postgres -q 2>/dev/null; then
        ok "Postgres is ready."
        break
    fi
    if [ "$i" -eq 30 ]; then
        fail "Postgres did not become ready in 30 seconds."
    fi
    sleep 1
done

# ---------------------------------------------------------------------------
# FULL RESEED: wipe and rebuild everything
# ---------------------------------------------------------------------------
if [ "$FULL_RESEED" = "true" ]; then
    echo ""
    echo "  ⚠️  ====================================================="
    echo "  ⚠️   FULL RESEED MODE — ALL DATA WILL BE DESTROYED"
    echo "  ⚠️  ====================================================="
    echo ""

    log "Dropping and recreating public schema..."
    run_sql "DROP SCHEMA public CASCADE;"
    run_sql "CREATE SCHEMA public;"
    run_sql "GRANT ALL ON SCHEMA public TO postgres, anon, authenticated, service_role;"

    if [ ! -d "$MIGRATIONS_DIR" ]; then
        fail "Migrations directory not found at $MIGRATIONS_DIR"
    fi

    log "Applying all migrations..."
    for file in $(ls "$MIGRATIONS_DIR"/*.sql | sort); do
        log "  -> Applying $(basename "$file")..."
        run_sql_file "$file" || fail "Migration failed: $(basename "$file")"
    done
    ok "All migrations applied."

# ---------------------------------------------------------------------------
# IDEMPOTENT MODE: only apply new migration files (default)
# ---------------------------------------------------------------------------
else
    log "Idempotent mode: checking for new migrations..."

    run_sql "CREATE TABLE IF NOT EXISTS _migration_history (
        filename TEXT PRIMARY KEY,
        applied_at TIMESTAMPTZ DEFAULT NOW()
    );" 2>/dev/null || true

    if [ ! -d "$MIGRATIONS_DIR" ]; then
        fail "Migrations directory not found at $MIGRATIONS_DIR"
    fi

    APPLIED=0
    SKIPPED=0
    for file in $(ls "$MIGRATIONS_DIR"/*.sql | sort); do
        fname=$(basename "$file")
        already_applied=$(run_sql_scalar "SELECT COUNT(*) FROM _migration_history WHERE filename='$fname';")
        if [ "$already_applied" -gt 0 ]; then
            log "  -> Skipping (already applied): $fname"
            SKIPPED=$((SKIPPED + 1))
        else
            log "  -> Applying: $fname..."
            run_sql_file "$file" || fail "Migration failed: $fname"
            run_sql "INSERT INTO _migration_history (filename) VALUES ('$fname') ON CONFLICT DO NOTHING;"
            APPLIED=$((APPLIED + 1))
        fi
    done
    ok "$APPLIED new migrations applied, $SKIPPED skipped."
fi

# ---------------------------------------------------------------------------
# Fix permissions (always safe to re-run)
# ---------------------------------------------------------------------------
log "Fixing schema permissions..."
run_sql "GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;"
run_sql "GRANT SELECT ON ALL TABLES IN SCHEMA public TO anon, authenticated;"
run_sql "GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;"
run_sql "GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO service_role;"
run_sql "GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO anon, authenticated, service_role;"

# ---------------------------------------------------------------------------
# Always re-apply the latest search_verses function (idempotent).
# This is a safety net for the idempotent migration path: even if the
# migration was marked as applied in _migration_history, a DB restore or
# reseed may have left an older function signature in place. The SQL uses
# DROP FUNCTION IF EXISTS + CREATE OR REPLACE so it is always safe to run.
# ---------------------------------------------------------------------------
SEARCH_MIGRATION="$MIGRATIONS_DIR/20251210000000_enable_hybrid_search.sql"
if [ -f "$SEARCH_MIGRATION" ]; then
    log "Re-applying latest search_verses function (always idempotent)..."
    run_sql_file "$SEARCH_MIGRATION" \
        || fail "Failed to apply search_verses function."
    ok "search_verses function is up to date."

    # Verify the function actually exists in the schema cache
    FUNC_EXISTS=$(run_sql_scalar "SELECT COUNT(*) FROM pg_proc WHERE proname='search_verses';")
    if [ "${FUNC_EXISTS:-0}" -lt 1 ]; then
        fail "search_verses function not found in pg_proc after applying migration!"
    fi
    ok "Verified: search_verses function exists in DB (count: $FUNC_EXISTS)."
else
    log "⚠️  Warning: $SEARCH_MIGRATION not found — skipping search_verses force-apply."
fi

# ---------------------------------------------------------------------------
# Seed data (scripts use upserts — safe to re-run)
# ---------------------------------------------------------------------------
cd "$APP_DIR"


if [ ! -d node_modules ]; then
    log "Installing npm dependencies..."
    npm install --silent
fi

# Patch the app .env with the local Supabase keys so that dotenvx in seed scripts
# uses the correct JWT tokens, not stale cloud keys from developer machines.
log "Syncing app .env with local Supabase credentials..."
ANON_KEY=$(grep "^ANON_KEY=" "$SUPABASE_DOCKER_DIR/.env" | cut -d= -f2)
DB_PASS=$(grep "^POSTGRES_PASSWORD=" "$SUPABASE_DOCKER_DIR/.env" | cut -d= -f2)

# Helper to upsert a key=value in the app .env
patch_env() {
    local KEY="$1" VAL="$2"
    if grep -q "^${KEY}=" .env 2>/dev/null; then
        sed -i "s|^${KEY}=.*|${KEY}=${VAL}|" .env
    else
        echo "${KEY}=${VAL}" >> .env
    fi
}

patch_env "SUPABASE_SERVICE_ROLE_KEY" "$SERVICE_KEY"
patch_env "DATABASE_URL"              "postgresql://postgres:${DB_PASS}@127.0.0.1:5432/postgres"
patch_env "PUBLIC_SUPABASE_URL"       "http://127.0.0.1:8000"
# CRITICAL: patch the public anon key used by the frontend/client.
# The .env checked in from dev machines may contain a stale cloud-project key
# (e.g. sb_publishable_...) which the local Supabase Kong will reject with 401.
patch_env "PUBLIC_SUPABASE_ANON_KEY" "$ANON_KEY"
ok "App .env synced with local Supabase credentials."

log "Seeding verses..."
npx tsx scripts/seed.ts

log "Seeding dictionary..."
npx tsx scripts/seed_dictionary.ts

log "Populating stems..."
npx tsx scripts/populate_stems.ts

log "Populating lemmas..."
npx tsx scripts/populate_lemmas.ts

log "Populating root English text..."
npx tsx scripts/populate_root_en.ts

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
log "Verifying seeded data..."
VERSE_COUNT=$(run_sql_scalar "SELECT COUNT(*) FROM verses;")
ROOT_COUNT=$(run_sql_scalar  "SELECT COUNT(*) FROM dictionary_roots;")
WORD_COUNT=$(run_sql_scalar  "SELECT COUNT(*) FROM dictionary_words;")

if [ "${VERSE_COUNT:-0}" -lt 100 ]; then
    fail "Verse count too low: ${VERSE_COUNT:-0} (expected ~6348)"
fi
if [ "${ROOT_COUNT:-0}" -lt 100 ]; then
    fail "Root count too low: ${ROOT_COUNT:-0}"
fi
if [ "${WORD_COUNT:-0}" -lt 1000 ]; then
    fail "Word count too low: ${WORD_COUNT:-0}"
fi

ok "Seeding verified: $VERSE_COUNT verses | $WORD_COUNT words | $ROOT_COUNT roots"
