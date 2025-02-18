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

# Configure Git to trust the repository path (fixing "safe" issue)
#git config --global --add safe.directory "$REPO_PATH"

# Check if the index.lock file exists and remove it if present
if [ -f ".git/index.lock" ]; then
    echo "Lock file exists. Removing .git/index.lock"
    rm -f .git/index.lock
fi

# Monitor the directory for changes
inotifywait -m -r -e modify,create,delete,move --format '%w%f' "$REPO_PATH" | while read -r FILE
do

	# Check if the file is within the .git directory and skip it
    if [[ "$FILE" == *".git"* ]]; then
        echo "File is inside .git directory, skipping Git operation."
        continue
    fi

 	echo "File changed: $FILE"
        # Check if the file exists before running Git commands
    if [ -e "$FILE" ]; then
        # Add the changes to Git
        git add "$FILE"

        # Get the current branch dynamically
        CURRENT_BRANCH=$(git symbolic-ref --short HEAD)

        # Commit with a timestamp
        TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
        git commit -m "Automated commit on file change at $TIMESTAMP"

        # Optionally, push changes to the current branch (dynamic branch name)
        git push origin "$CURRENT_BRANCH"
    else
        echo "File does not exist, skipping Git operation."
    fi
done
