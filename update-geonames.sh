#!/usr/bin/env bash

set -euo pipefail

CITIES="cities500.txt"
CITIES_ZIP="cities500.zip"
ADMINS="admin1CodesASCII.txt"
COUNTRIES="countryInfo.txt"

OUTPUT="places.csv"
SQLITE_FILE="places.sqlite"
IMPORT_SQL="places-import.sql"

DB_NAME="swm-places"
WRANGLER_VERSION="4.131.1"

EXPECTED_MIN_ROWS=200000

# ---------------------------------------------------------
# Requirements
# ---------------------------------------------------------

for command in curl unzip awk jq sqlite3 node npx; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Missing required command: $command" >&2
        exit 1
    fi
done

# GitHub Actions should provide these as secrets.
if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    echo "CLOUDFLARE_API_TOKEN is not set." >&2
    exit 1
fi

if [[ -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]]; then
    echo "CLOUDFLARE_ACCOUNT_ID is not set." >&2
    exit 1
fi

# ---------------------------------------------------------
# Cleanup
# ---------------------------------------------------------

rm -f \
    "$CITIES" \
    "$CITIES_ZIP" \
    "$ADMINS" \
    "$COUNTRIES" \
    "$OUTPUT" \
    "$OUTPUT.tmp" \
    "$SQLITE_FILE" \
    "$IMPORT_SQL"

sleep 10

# ---------------------------------------------------------
# Download GeoNames
# ---------------------------------------------------------

echo
echo "Downloading GeoNames data..."

curl --fail --location --silent --show-error \
    --output "$CITIES_ZIP" \
    "https://download.geonames.org/export/dump/$CITIES_ZIP"

unzip -q -o "$CITIES_ZIP"
rm "$CITIES_ZIP"

curl --fail --location --silent --show-error \
    --output "$ADMINS" \
    "https://download.geonames.org/export/dump/$ADMINS"

curl --fail --location --silent --show-error \
    --output "$COUNTRIES" \
    "https://download.geonames.org/export/dump/$COUNTRIES"

for file in "$CITIES" "$ADMINS" "$COUNTRIES"; do
    if [[ ! -s "$file" ]]; then
        echo "Missing or empty GeoNames file: $file" >&2
        exit 1
    fi
done

# ---------------------------------------------------------
# Transform GeoNames -> clean CSV
# ---------------------------------------------------------

echo
echo "Transforming GeoNames data..."

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

rm "$OUTPUT.tmp"

CSV_ROWS=$(($(wc -l < "$OUTPUT") - 1))

echo "CSV rows: $CSV_ROWS"

if (( CSV_ROWS < EXPECTED_MIN_ROWS )); then
    echo "GeoNames row count is suspiciously low: $CSV_ROWS" >&2
    exit 1
fi

# ---------------------------------------------------------
# Build local SQLite database
# ---------------------------------------------------------

echo
echo "Building temporary SQLite database..."

sqlite3 "$SQLITE_FILE" <<'SQL'
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
SQL

sqlite3 "$SQLITE_FILE" <<SQL
.mode csv
.import --skip 1 "$OUTPUT" places
SQL

# ---------------------------------------------------------
# Local validation
# ---------------------------------------------------------

SQLITE_ROWS=$(
    sqlite3 "$SQLITE_FILE" \
        'SELECT COUNT(*) FROM places;'
)

if [[ "$CSV_ROWS" -ne "$SQLITE_ROWS" ]]; then
    echo "CSV/SQLite row count mismatch." >&2
    echo "CSV:    $CSV_ROWS" >&2
    echo "SQLite: $SQLITE_ROWS" >&2
    exit 1
fi

ADELAIDE_COUNT=$(
    sqlite3 "$SQLITE_FILE" "
        SELECT COUNT(*)
        FROM places
        WHERE ascii_name = 'Adelaide'
          AND country_code = 'AU'
          AND timezone = 'Australia/Adelaide';
    "
)

if [[ "$ADELAIDE_COUNT" -lt 1 ]]; then
    echo "Adelaide sanity check failed." >&2
    exit 1
fi

echo "Local validation passed: $SQLITE_ROWS places."

# ---------------------------------------------------------
# Add indexes AFTER import
#
# This makes bulk loading faster than maintaining indexes
# while 235k records are being inserted.
# ---------------------------------------------------------

sqlite3 "$SQLITE_FILE" <<'SQL'
CREATE INDEX idx_places_ascii_name
    ON places(ascii_name);

CREATE INDEX idx_places_name
    ON places(name);

CREATE INDEX idx_places_country_code
    ON places(country_code);

CREATE INDEX idx_places_population
    ON places(population DESC);
SQL

# ---------------------------------------------------------
# Generate D1-compatible SQL
# ---------------------------------------------------------

echo
echo "Generating D1 import SQL..."

{
    # Replace the existing table on every weekly refresh.
    echo 'DROP TABLE IF EXISTS places;'

    sqlite3 "$SQLITE_FILE" ".dump places" \
        | sed \
            -e '/^BEGIN TRANSACTION;$/d' \
            -e '/^COMMIT;$/d' \
            -e '/^PRAGMA foreign_keys=OFF;$/d'
} > "$IMPORT_SQL"

echo "Import SQL:"
ls -lh "$IMPORT_SQL"

# ---------------------------------------------------------
# Validate SQL statement size
# ---------------------------------------------------------

MAX_STATEMENT_BYTES=$(
    awk '
        {
            length_bytes += length($0) + 1

            if ($0 ~ /;[[:space:]]*$/) {
                if (length_bytes > max_bytes) {
                    max_bytes = length_bytes
                }

                length_bytes = 0
            }
        }

        END {
            print max_bytes + 0
        }
    ' "$IMPORT_SQL"
)

echo "Largest SQL statement: $MAX_STATEMENT_BYTES bytes"

if (( MAX_STATEMENT_BYTES > 100000 )); then
    echo "Generated SQL contains a statement exceeding D1 limits." >&2
    exit 1
fi

# ---------------------------------------------------------
# Verify D1 exists
# ---------------------------------------------------------

echo
echo "Checking D1 database..."

DB_ID="$(
    npx --yes "wrangler@$WRANGLER_VERSION" d1 list --json \
        | jq -r \
            --arg name "$DB_NAME" \
            '.[] | select(.name == $name) | .uuid'
)"

if [[ -z "$DB_ID" || "$DB_ID" == "null" ]]; then
    echo "D1 database '$DB_NAME' does not exist." >&2
    echo "Run the init script first." >&2
    exit 1
fi

echo "Using D1 database: $DB_NAME ($DB_ID)"

# ---------------------------------------------------------
# Import into D1
# ---------------------------------------------------------

echo
echo "Updating Cloudflare D1..."

MAX_ATTEMPTS=3

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
    echo "Import attempt $attempt/$MAX_ATTEMPTS..."

    if npx --yes "wrangler@$WRANGLER_VERSION" d1 execute "$DB_NAME" \
        --remote \
        --yes \
        --file="$IMPORT_SQL"; then

        break
    fi

    if [[ "$attempt" -eq "$MAX_ATTEMPTS" ]]; then
        echo "D1 import failed after $MAX_ATTEMPTS attempts." >&2
        exit 1
    fi

    sleep $((attempt * 10))
done

# ---------------------------------------------------------
# Verify remote database
# ---------------------------------------------------------

echo
echo "Verifying remote database..."

REMOTE_RESULT="$(
    npx --yes "wrangler@$WRANGLER_VERSION" d1 execute "$DB_NAME" \
        --remote \
        --json \
        --command='SELECT COUNT(*) AS count FROM places;'
)"

REMOTE_ROWS="$(
    printf '%s' "$REMOTE_RESULT" \
        | jq -r '.[0].results[0].count'
)"

echo "Local rows:  $SQLITE_ROWS"
echo "Remote rows: $REMOTE_ROWS"

if [[ "$REMOTE_ROWS" -ne "$SQLITE_ROWS" ]]; then
    echo "Remote D1 verification failed." >&2
    exit 1
fi

echo
echo "GeoNames update complete."