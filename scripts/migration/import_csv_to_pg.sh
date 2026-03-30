#!/bin/bash

# Get the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load environment variables from .env file in project root
if [ -f "$PROJECT_ROOT/.env" ]; then
    source "$PROJECT_ROOT/.env"
else
    echo "ERROR: .env file not found in $PROJECT_ROOT"
    exit 1
fi

# Export directory
EXPORT_DIR="$PROJECT_ROOT/exports"
LOAD_FILES_DIR="$PROJECT_ROOT/exports"  # Directory where .load files will be saved

# Check if EXPORT_TABLES variable is set in .env file
if [ -z "$EXPORT_TABLES" ]; then
  echo "ERROR: EXPORT_TABLES is not set in the .env file."
  exit 1
fi

# Check if pgloader is installed
command -v pgloader >/dev/null 2>&1 || { echo "ERROR: pgloader is not installed. Please install pgloader."; exit 1; }

# Create directory for .load files if it doesn't exist
mkdir -p "$LOAD_FILES_DIR"

# Loop through the tables defined in the .env file
IFS=',' read -r -a TABLES <<< "$EXPORT_TABLES"

# Loop through each table
for TABLE_NAME in "${TABLES[@]}"; do
    # Trim whitespace
    TABLE_NAME=$(echo "$TABLE_NAME" | xargs)
    
    # Directory for the current table
    TABLE_DIR="$EXPORT_DIR/$TABLE_NAME"

    # Check if directory for table exists
    if [ -d "$TABLE_DIR" ]; then
        echo "Generating .load files for table: $TABLE_NAME"

        # Loop through each CSV file in the table's folder
        CSV_FILES=("$TABLE_DIR"/*.csv)
        if [ ${#CSV_FILES[@]} -gt 0 ] && [ -f "${CSV_FILES[0]}" ]; then
            file_counter=1
            for CSV_FILE in "${CSV_FILES[@]}"; do
                if [ -f "$CSV_FILE" ]; then
                    echo "Found CSV file: $CSV_FILE"

                    # Generate a numbered load file for the current CSV file
                    LOAD_FILE="$LOAD_FILES_DIR/$TABLE_NAME-$file_counter.load"
                    #LOAD_FILE="$LOAD_FILES_DIR/$TABLE_NAME.load"

                    echo "Generating load file: $LOAD_FILE"

                    # Get relative path from project root to CSV file
                    CSV_REL_PATH="$TABLE_NAME/$(basename "$CSV_FILE")"

                    # Write the pgloader command to the .load file, adjusting the FROM path
                    cat <<EOF > "$LOAD_FILE"
LOAD CSV
    FROM '$CSV_REL_PATH'
    INTO postgresql://$PG_USER:$PG_PASSWORD@$PG_HOST:$PG_PORT/$PG_DB
    TARGET TABLE $TABLE_NAME
    WITH 
        fields terminated by ',',
        fields optionally enclosed by '"',
        fields escaped by '\\';
EOF

                    echo ".load file generated for $CSV_FILE"
                    file_counter=$((file_counter + 1))
                fi
            done
        else
            echo "ERROR: No CSV files found in $TABLE_DIR"
        fi
    else
        echo "ERROR: Directory for table $TABLE_NAME not found in $EXPORT_DIR"
    fi
done

echo "Generation of .load files completed. Files are in $LOAD_FILES_DIR directory."