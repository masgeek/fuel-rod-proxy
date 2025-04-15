#!/bin/bash

# Get the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load variables from the .env file in project root
if [ -f "$PROJECT_ROOT/.env" ]; then
    # Source the .env file to read environment variables
    source "$PROJECT_ROOT/.env"
else
    echo ".env file not found in $PROJECT_ROOT. Please create a .env file with the table names."
    exit 1
fi

# Check if EXPORT_TABLES is defined in the .env file
if [ -z "$EXPORT_TABLES" ]; then
    echo "EXPORT_TABLES not defined in .env file. Please specify tables to export."
    exit 1
fi

# Configuration variables
MYSQL_CONTAINER_NAME="maria"  # Name of your Docker container
EXPORT_DIR="$PROJECT_ROOT/exports"  # Directory for storing exported CSV files
CSV_DELIMITER=","  # CSV delimiter (can be changed to tab or others)
CSV_ENCLOSURE="\""
CSV_ESCAPED_BY="\\\\"  # Corrected: Need to escape the backslash twice for shell and SQL
BATCH_SIZE=1500000  # Number of rows per CSV file

# Create the main export directory if it doesn't exist
mkdir -p "$EXPORT_DIR"

process_html_in_csv() {
    local FILENAME=$1
    echo "Post-processing HTML content in $FILENAME"
    
    # Create a temporary file
    TEMP_FILE="${FILENAME}.tmp"
    
    # Process the CSV file with awk to properly handle HTML content
    # This ensures quotes inside HTML are properly escaped
    awk -F "$CSV_DELIMITER" -v OFS="$CSV_DELIMITER" -v q="$CSV_ENCLOSURE" -v esc="\\" '
    {
        for (i=1; i<=NF; i++) {
            # If field contains HTML tags, ensure proper escaping
            if ($i ~ /<[^>]+>/) {
                # Replace any existing enclosure chars with escaped version
                gsub(q, esc q, $i);
                # Enclose the field
                $i = q $i q;
            }
        }
        print $0;
    }' "$FILENAME" > "$TEMP_FILE"
    
    # Replace original file with processed file
    mv "$TEMP_FILE" "$FILENAME"
}

# Function to export a table
export_table() {
    local TABLE_NAME=$1
    echo "Exporting table: $TABLE_NAME"

    # Create a subfolder for the table inside the export directory
    TABLE_EXPORT_DIR="$EXPORT_DIR/$TABLE_NAME"
    mkdir -p "$TABLE_EXPORT_DIR"

    # Get the total number of rows for the current table
    TOTAL_ROWS=$(docker exec -i $MYSQL_CONTAINER_NAME mariadb -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DB" -se "SELECT COUNT(*) FROM $TABLE_NAME")
    echo "Total rows in $TABLE_NAME: $TOTAL_ROWS"

    # Calculate number of batches (rounded up)
    BATCHES=$(( ($TOTAL_ROWS + $BATCH_SIZE - 1) / $BATCH_SIZE ))
    echo "Will export in $BATCHES batches"

    # Export each batch
    CURRENT_ID=0
    for (( i=1; i<=$BATCHES; i++ ))
    do
        NEXT_ID=$(( $CURRENT_ID + $BATCH_SIZE ))
        FILENAME="${TABLE_EXPORT_DIR}/${TABLE_NAME}_batch_${i}.csv"

        echo "Exporting batch $i/$BATCHES (rows $CURRENT_ID-$NEXT_ID) to $FILENAME"
        
        # Export this batch to CSV inside Docker container (using /tmp directory)
        docker exec -i $MYSQL_CONTAINER_NAME mariadb -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DB" \
            -e "SELECT * INTO OUTFILE '/tmp/${TABLE_NAME}_batch_${i}.csv' 
                FIELDS TERMINATED BY '$CSV_DELIMITER' 
                OPTIONALLY ENCLOSED BY '$CSV_ENCLOSURE' 
                ESCAPED BY '\\\\' 
                LINES TERMINATED BY '\n' 
                FROM $TABLE_NAME LIMIT $CURRENT_ID, $BATCH_SIZE;"

        # Check if export was successful by looking for the file
        docker exec -i $MYSQL_CONTAINER_NAME ls /tmp | grep "${TABLE_NAME}_batch_${i}.csv"

        if [ $? -ne 0 ]; then
            echo "Error: Export file not found in /tmp for $TABLE_NAME batch $i. Please check for errors in the MariaDB container."
            exit 1
        fi

        # Copy the exported CSV file from the container to the host machine
        docker cp "$MYSQL_CONTAINER_NAME:/tmp/${TABLE_NAME}_batch_${i}.csv" "$FILENAME"

        # Remove \N from the CSV file
        sed -i 's/\\N//g' "$FILENAME"
        process_html_in_csv "$FILENAME"
        
        # Clean up the temporary file inside the container
        docker exec -i $MYSQL_CONTAINER_NAME rm "/tmp/${TABLE_NAME}_batch_${i}.csv"
        
        CURRENT_ID=$NEXT_ID
        
        # Verify the export
        EXPORTED_ROWS=$(wc -l < "$FILENAME")
        echo "Exported $EXPORTED_ROWS rows to $FILENAME"
    done

    echo "Export for $TABLE_NAME completed. Files are in $TABLE_EXPORT_DIR directory"
}

# Main logic
# Convert the comma-separated string in EXPORT_TABLES into an array
IFS=',' read -ra TABLES <<< "$EXPORT_TABLES"

# Loop through all specified tables and export them
for TABLE_NAME in "${TABLES[@]}"
do
    # Trim whitespace
    TABLE_NAME=$(echo "$TABLE_NAME" | xargs)
    export_table "$TABLE_NAME"
done

echo "All exports completed."