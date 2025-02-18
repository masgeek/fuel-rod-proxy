#!/bin/bash

# Load environment variables from .env file

# Define the .env file path
ENV_FILE="/home/agwise/services/proxy/.env"

# Load environment variables from the .env file if it exists
if [ -f "$ENV_FILE" ]; then
    echo "Loading environment variables from .env file..."
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "Warning: .env file not found at $ENV_FILE."
fi

# Check if REPO_PATH is set
if [ -z "$REPO_PATH" ]; then
    echo "Error: REPO_PATH is not set in the .env file."
    exit 1
fi

# Navigate to the repository
cd "$REPO_PATH" || { echo "Error: Repository path not found."; exit 1; }

# Monitor the directory for changes
inotifywait -m -r -e modify,create,delete,move --format '%w%f' "$REPO_PATH" | while read -r FILE
do
    echo "File changed: $FILE"

    # Add the changes to Git
    git add -A

    # Commit with a timestamp
    TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
    git commit -m "Automated commit on file change at $TIMESTAMP"

    # Optionally, push changes (requires configured Git remote)
    #git push origin main
    git push
done
