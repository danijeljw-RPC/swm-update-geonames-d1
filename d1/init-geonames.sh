#!/usr/bin/env bash

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

CITIES="cities500.txt"
CITIES_ZIP="cities500.zip"
ADMINS="admin1CodesASCII.txt"
COUNTRIES="countryInfo.txt"
OUTPUT="places.csv"

SCHEMA_FILE="schema.sql"
SQLITE_FILE="places.sqlite"
IMPORT_SQL="places-import.sql"
RAW_DUMP="places-import.raw.sql"

DB_NAME="swm-places"
BINDING="swm_places"
WRANGLER_VERSION="4.131.1"

GEONAMES_BASE_URL="https://download.geonames.org/export/dump"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

log() {
    printf '\n%s\n' "$*"
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

wrangler() {
    npx --yes "wrangler@$WRANGLER_VERSION" "$@"
}

# -----------------------------------------------------------------------------
# Dependencies
# -----------------------------------------------------------------------------

for command in curl unzip awk jq sqlite3 npx; do
    require_command "$command"
done

# -----------------------------------------------------------------------------
# Clean previous generated/source files
# -----------------------------------------------------------------------------

for file in \
    "$CITIES" \
    "$CITIES_ZIP" \
    "$ADMINS" \
    "$COUNTRIES" \
    "$OUTPUT" \
    "$OUTPUT.tmp" \
    "$SCHEMA_FILE" \
    "$SQLITE_FILE" \
    "$IMPORT_SQL" \
    "$RAW_DUMP"; do

    rm -f "$file"
done

# -----------------------------------------------------------------------------
# Download GeoNames source data
# -----------------------------------------------------------------------------

log "Downloading GeoNames data..."

curl --fail --location --retry 3 --retry-all-errors \
    --output "$CITIES_ZIP" \
    "$GEONAMES_BASE_URL/$CITIES_ZIP"

unzip -o "$CITIES_ZIP"
rm -f "$CITIES_ZIP"

curl --fail --location --retry 3 --retry-all-errors \
    --output "$ADMINS" \
    "$GEONAMES_BASE_URL/$ADMINS"

curl --fail --location --retry 3 --retry-all-errors \
    --output "$COUNTRIES" \
    "$GEONAMES_BASE_URL/$COUNTRIES"

for file in "$CITIES" "$ADMINS" "$COUNTRIES"; do
    if [[ ! -f "$file" ]]; then
        echo "Missing required file: $file" >&2
        exit 1
    fi
done

# -----------------------------------------------------------------------------
# Transform GeoNames into a clean CSV
# -----------------------------------------------------------------------------

log "Transforming GeoNames data..."

awk \
    -v cities_file="$CITIES" \
    -v admins_file="$ADMINS" \
    -v countries_file="$COUNTRIES" \
    '
    BEGIN {
        FS = "\t"
        OFS = ","
    }

    function csv(value, escaped) {
        escaped = value
        gsub(/"/, "\"\"", escaped)
        return "\"" escaped "\""
    }

    FILENAME == countries_file {
        if ($0 ~ /^#/ || NF == 0) {
            next
        }

        country_name[$1] = $5
        next
    }

    FILENAME == admins_file {
        admin_name[$1] = $2
        next
    }

    FILENAME == cities_file {
        country_code = $9
        admin_code = $11
        admin_key = country_code "." admin_code

        print \
            csv($1), \
            csv($2), \
            csv($3), \
            csv($4), \
            $5, \
            $6, \
            csv(country_code), \
            csv(country_name[country_code]), \
            csv(admin_name[admin_key]), \
            ($15 == "" ? 0 : $15), \
            csv($18)
    }
    ' \
    "$COUNTRIES" \
    "$ADMINS" \
    "$CITIES" \
    > "$OUTPUT.tmp"

{
    echo 'id,name,ascii_name,alternate_names,latitude,longitude,country_code,country,region,population,timezone'
    cat "$OUTPUT.tmp"
} > "$OUTPUT"

rm -f "$OUTPUT.tmp"

log "CSV created."
wc -l "$OUTPUT"
ls -lh "$OUTPUT"

# -----------------------------------------------------------------------------
# Ensure Cloudflare authentication works
# -----------------------------------------------------------------------------

log "Checking Cloudflare authentication..."
wrangler whoami >/dev/null

# -----------------------------------------------------------------------------
# Create D1 database only if it does not already exist
# -----------------------------------------------------------------------------

if wrangler d1 list --json \
    | jq -e --arg name "$DB_NAME" '.[] | select(.name == $name)' \
    >/dev/null; then

    log "D1 database '$DB_NAME' already exists."
else
    log "Creating D1 database '$DB_NAME'..."

    wrangler d1 create "$DB_NAME" \
        --location=oc \
        --binding="$BINDING" \
        --update-config=false
fi

DB_ID="$(
    wrangler d1 list --json \
        | jq -r --arg name "$DB_NAME" '.[] | select(.name == $name) | .uuid' \
        | head -n 1
)"

if [[ -z "$DB_ID" || "$DB_ID" == "null" ]]; then
    echo "Unable to resolve database ID for '$DB_NAME'." >&2
    exit 1
fi

log "Using D1 database: $DB_NAME ($DB_ID)"

# -----------------------------------------------------------------------------
# Build local SQLite database
# -----------------------------------------------------------------------------

log "Creating schema..."

cat > "$SCHEMA_FILE" <<'SQL'
DROP TABLE IF EXISTS places;

CREATE TABLE places (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    ascii_name TEXT NOT NULL,
    alternate_names TEXT,
    latitude REAL NOT NULL,
    longitude REAL NOT NULL,
    country_code TEXT NOT NULL,
    country TEXT NOT NULL,
    region TEXT,
    population INTEGER NOT NULL DEFAULT 0,
    timezone TEXT NOT NULL
);

CREATE INDEX idx_places_ascii_name
    ON places(ascii_name);

CREATE INDEX idx_places_name
    ON places(name);

CREATE INDEX idx_places_country_code
    ON places(country_code);

CREATE INDEX idx_places_population
    ON places(population DESC);
SQL

log "Building temporary SQLite database..."

sqlite3 "$SQLITE_FILE" <<SQL
.read "$SCHEMA_FILE"
.mode csv
.import --skip 1 "$OUTPUT" places
SQL

# -----------------------------------------------------------------------------
# Validate local data before touching D1
# -----------------------------------------------------------------------------

EXPECTED_ROWS=$(( $(wc -l < "$OUTPUT") - 1 ))
ACTUAL_ROWS="$(sqlite3 "$SQLITE_FILE" 'SELECT COUNT(*) FROM places;')"

if [[ "$ACTUAL_ROWS" -ne "$EXPECTED_ROWS" ]]; then
    echo "Row-count mismatch: CSV=$EXPECTED_ROWS SQLite=$ACTUAL_ROWS" >&2
    exit 1
fi

log "Local SQLite verification passed: $ACTUAL_ROWS places."

sqlite3 "$SQLITE_FILE" <<'SQL'
.headers on
.mode column
SELECT
    name,
    region,
    country,
    latitude,
    longitude,
    timezone,
    population
FROM places
WHERE ascii_name = 'Adelaide'
ORDER BY population DESC;
SQL

# -----------------------------------------------------------------------------
# Generate a D1-compatible SQL dump
# -----------------------------------------------------------------------------

log "Generating D1 import SQL..."

sqlite3 "$SQLITE_FILE" ".dump places" > "$RAW_DUMP"

# Cloudflare D1 import expects SQLite dumps without explicit transaction
# wrappers. The foreign_keys pragma is also unnecessary for this standalone
# table import.
awk '
    $0 == "BEGIN TRANSACTION;" { next }
    $0 == "COMMIT;" { next }
    $0 == "PRAGMA foreign_keys=OFF;" { next }
    { print }
' "$RAW_DUMP" > "$IMPORT_SQL"

rm -f "$RAW_DUMP"

log "Import SQL created."
ls -lh "$IMPORT_SQL"

# D1 currently limits an individual SQL statement to 100 KB. sqlite3 .dump
# emits one INSERT statement per row, so fail early if any generated statement
# exceeds that limit.
MAX_STATEMENT_BYTES="$(LC_ALL=C awk '{ if (length($0) > max) max = length($0) } END { print max + 0 }' "$IMPORT_SQL")"

printf 'Largest SQL statement: %s bytes\n' "$MAX_STATEMENT_BYTES"

if (( MAX_STATEMENT_BYTES > 100000 )); then
    echo "A generated SQL statement exceeds D1's 100,000-byte statement limit." >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# Import into remote D1
# -----------------------------------------------------------------------------

log "Importing into Cloudflare D1..."

IMPORT_ATTEMPTS=3
IMPORT_OK=false

for attempt in $(seq 1 "$IMPORT_ATTEMPTS"); do
    echo "Import attempt $attempt/$IMPORT_ATTEMPTS..."

    if wrangler d1 execute "$DB_NAME" \
        --remote \
        --yes \
        --file="$IMPORT_SQL"; then

        IMPORT_OK=true
        break
    fi

    if (( attempt < IMPORT_ATTEMPTS )); then
        echo "D1 import failed; retrying..." >&2
        sleep $(( attempt * 5 ))
    fi
done

if [[ "$IMPORT_OK" != true ]]; then
    echo "D1 import failed after $IMPORT_ATTEMPTS attempts." >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# Verify remote D1
# -----------------------------------------------------------------------------

log "Verifying remote D1 database..."

wrangler d1 execute "$DB_NAME" \
    --remote \
    --yes \
    --command="
        SELECT COUNT(*) AS place_count FROM places;
        SELECT
            name,
            region,
            country,
            timezone,
            population
        FROM places
        WHERE ascii_name = 'Adelaide'
        ORDER BY population DESC
        LIMIT 5;
    "

log "GeoNames import complete."
