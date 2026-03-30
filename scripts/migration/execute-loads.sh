#!/bin/bash

# Get the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load environment variables from .env file in project root
if [ -f "$PROJECT_ROOT/.env" ]; then
  echo "Loading environment variables from $PROJECT_ROOT/.env file"
  source "$PROJECT_ROOT/.env"
else
  echo "Error: .env file not found in $PROJECT_ROOT."
  exit 1
fi

# Check if EXPORT_TABLES variable exists
if [ -z "$EXPORT_TABLES" ]; then
  echo "Error: EXPORT_TABLES variable not found in .env file."
  exit 1
fi

# Directory where .load files are stored
LOAD_DIR="$PROJECT_ROOT/exports"

# Check if the load directory exists
if [ ! -d "$LOAD_DIR" ]; then
  echo "Error: Load directory '$LOAD_DIR' not found."
  exit 1
fi

echo "Processing tables: $EXPORT_TABLES"
echo "---------------------------------------------"

# Convert comma-separated list to array
IFS=',' read -r -a TABLES <<< "$EXPORT_TABLES"

# Process each table
for table in "${TABLES[@]}"; do
  # Trim whitespace
  table=$(echo "$table" | xargs)
  
  echo "Looking for load files for table: $table"
  
  # Find all load files containing the table name
  load_files=$(find "$LOAD_DIR" -name "*${table}*.load" -type f)
  
  # Check if any load files were found
  if [ -z "$load_files" ]; then
    echo "Warning: No load files found for table '$table'. Skipping."
    continue
  fi
  
  # Count the number of files found
  file_count=$(echo "$load_files" | wc -l)
  echo "Found $file_count load file(s) for table: $table"
  
  # Process each load file for this table
  for load_file in $load_files; do
    echo "Processing: $(basename "$load_file")"
    echo "Executing: $load_file"
    
    # Execute the load file with pgloader
    pgloader "$load_file"
    
    # Check if pgloader was successful
    if [ $? -eq 0 ]; then
      echo "Import successful for: $(basename "$load_file")"
    else
      echo "Error importing data for: $(basename "$load_file")"
    fi
    
    echo "---"
  done
  
  echo "---------------------------------------------"
done

echo "All imports completed."