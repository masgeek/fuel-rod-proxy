#!/bin/bash

# Function to display usage information
usage() {
    echo "Usage: $(basename "$0") [OPTIONS]"
    echo "Perform pattern substitution in specified files using sed."
    echo
    echo "Options:"
    echo "  -s, --search <search_pattern>       Specify the search pattern to replace"
    echo "  -r, --replace <replacement_text>    Specify the replacement text"
    echo "  -f, --files <file_pattern>          Specify the file pattern (e.g., /path/to/files/*)"
    echo "  -u, --sudo                          Run sed with sudo (root privileges)"
    echo "  -h, --help                          Display this help message"
    echo
    echo "Environment Variables:"
    echo "  SEARCH_PATTERN                      Search pattern to replace (optional)"
    echo "  REPLACEMENT_TEXT                    Replacement text (optional)"
    echo "  FILE_PATTERN                        File pattern (optional)"
    echo "  You can also specify these parameters using environment variables."
    echo "  If using a .env file, define these variables in the .env file."
    echo
    echo "Example:"
    echo "  $(basename "$0") -s 'old_pattern' -r 'new_pattern' -f '/path/to/files/*' -u"
    echo "  $(basename "$0") --search 'old_pattern' --replace 'new_pattern' --files '/path/to/files/*' --sudo"
    echo
    exit 1
}

# Default value for sudo usage (false)
use_sudo=false

# Load parameters from .env file (if present)
if [[ -f .env ]]; then
    echo "Loading parameters from .env file..."
    source .env
fi

# Initialize variables from .env file or environment variables
search_pattern="${SEARCH_PATTERN:-}"
replacement_text="${REPLACEMENT_TEXT:-}"
file_pattern="${FILE_PATTERN:-}"

# Parse command-line options using getopts
while getopts ":s:r:f:u-:h" opt; do
    case $opt in
        s | search)
            search_pattern="$OPTARG"
            ;;
        r | replace)
            replacement_text="$OPTARG"
            ;;
        f | files)
            file_pattern="$OPTARG"
            ;;
        u | sudo)
            use_sudo=true
            ;;
        h | help)
            usage
            ;;
        *)
            usage
            ;;
    esac
done

# Validate required options
if [[ -z "$search_pattern" || -z "$replacement_text" || -z "$file_pattern" ]]; then
    echo "Error: Missing required options or environment variables."
    usage
fi

# Function to perform pattern substitution using sed
replace_in_files() {
    if $use_sudo; then
        sudo sed -i "s|$search_pattern|$replacement_text|g" $file_pattern
    else
        sed -i "s|$search_pattern|$replacement_text|g" $file_pattern
    fi
}

# Call the function to perform the substitution
replace_in_files

echo "Pattern substitution completed successfully!"
