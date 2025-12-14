#!/bin/bash

# Function to log messages
log() {
    local message="$1"
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message"
}

# Function to handle errors
handle_error() {
    log "ERROR: $1"
    exit 1
}

# Set directory of the script
dir="$(dirname "$(realpath "$0")")"

# Load environment variables from .backup file if present
if [[ -f "$dir/.backup" ]]; then
    source "$dir/.backup"
    log "Loaded environment variables from .backup file"
fi

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -b|--base-dir) shift; base_dir="$1" ;;
        --keep-days) shift; days_to_keep="$1" ;;
        --compress-sql) compress_sql=true ;;
        --compress-n8n) compress_n8n=true ;;
        --dry-run) dry_run=true ;;
        --verbose) verbose=true ;;
        *) handle_error "Invalid argument: $1" ;;
    esac
    shift
done

# Assign variables with fallback priorities
base_dir="${base_dir:-${BACKUP_DIR:-$dir/db-backup}}"
days_to_keep="${days_to_keep:-${ARCHIVE_KEEP_DAYS:-30}}"
compress_sql="${compress_sql:-${COMPRESS_SQL:-true}}"
compress_n8n="${compress_n8n:-${COMPRESS_N8N:-true}}"
dry_run="${dry_run:-false}"
verbose="${verbose:-false}"

# Set backup directory (postgres subfolder for multi-database backups)
postgres_backup_dir="$base_dir/postgres"
n8n_backup_dir="$base_dir/n8n"

log "Base backup directory: $base_dir"
log "PostgreSQL backup directory: $postgres_backup_dir"
log "n8n backup directory: $n8n_backup_dir"
log "Days to keep: $days_to_keep"
[[ "$dry_run" == "true" ]] && log "DRY RUN MODE - No files will be modified"

# Function to get database names from backup files
get_databases_from_backups() {
    local backup_dir="$1"
    declare -a databases

    # Check for compressed backups
    for archive in "$backup_dir"/*.tar.gz; do
        [[ -f "$archive" ]] || continue
        db_name=$(basename "$archive" | grep -o '^[^_]*')
        if [[ -n "$db_name" && ! " ${databases[*]} " =~ " ${db_name} " ]]; then
            databases+=("$db_name")
        fi
    done

    # Check for uncompressed directories
    for dir_path in "$backup_dir"/*/; do
        [[ -d "$dir_path" ]] || continue
        db_name=$(basename "$dir_path" | grep -o '^[^_]*')
        if [[ -n "$db_name" && ! " ${databases[*]} " =~ " ${db_name} " ]]; then
            databases+=("$db_name")
        fi
    done

    echo "${databases[@]}"
}

# Function to compress PostgreSQL SQL files
compress_postgres_sql_files() {
    log "Processing PostgreSQL SQL files..."

    if [[ ! -d "$postgres_backup_dir" ]]; then
        log "PostgreSQL backup directory not found: $postgres_backup_dir"
        return
    fi

    # Get all database names
    databases=($(get_databases_from_backups "$postgres_backup_dir"))

    if [[ ${#databases[@]} -eq 0 ]]; then
        log "No database backups found in $postgres_backup_dir"
        return
    fi

    log "Found ${#databases[@]} databases: ${databases[*]}"

    # Process each database
    for database in "${databases[@]}"; do
        log "Processing database: $database"

        # Find uncompressed backup directories for this database
        find "$postgres_backup_dir" -name "${database}_*" -type d | while read -r backup_dir; do
            [[ -d "$backup_dir" ]] || continue

            # Check if directory has already been compressed
            dir_name=$(basename "$backup_dir")
            archive_file="$postgres_backup_dir/${dir_name}.tar.gz"

            if [[ -f "$archive_file" ]]; then
                log "Skipping $dir_name - already compressed as $archive_file"
                continue
            fi

            log "Compressing backup directory: $dir_name"

            if [[ "$dry_run" == "false" ]]; then
                if tar -czf "$archive_file" -C "$postgres_backup_dir" "$dir_name"; then
                    zip_size=$(du -h "$archive_file" | cut -f1)
                    log "Successfully created archive: $archive_file (Size: $zip_size)"

                    # Remove the original directory after successful compression
                    rm -rf "$backup_dir"
                    log "Removed original directory: $backup_dir"
                else
                    log "Failed to compress: $dir_name"
                fi
            else
                log "[DRY RUN] Would compress: $backup_dir to $archive_file"
                log "[DRY RUN] Would remove: $backup_dir"
            fi
        done

        # Also find and compress individual SQL files (older format)
        find "$postgres_backup_dir" -name "${database}_*.sql" -type f | while read -r sql_file; do
            [[ -f "$sql_file" ]] || continue

            zip_file="${sql_file}.gz"
            log "Compressing SQL file: $(basename "$sql_file")"

            if [[ "$dry_run" == "false" ]]; then
                if gzip -c "$sql_file" > "$zip_file"; then
                    zip_size=$(du -h "$zip_file" | cut -f1)
                    log "Successfully compressed: $zip_file (Size: $zip_size)"
                    rm "$sql_file"
                    log "Removed original SQL file: $sql_file"
                else
                    log "Failed to compress: $sql_file"
                fi
            else
                log "[DRY RUN] Would compress: $sql_file to $zip_file"
                log "[DRY RUN] Would remove: $sql_file"
            fi
        done
    done
}

# Function to compress n8n backup subfolders
compress_n8n_backups() {
    log "Processing n8n backup subfolders..."

    if [[ ! -d "$n8n_backup_dir" ]]; then
        log "n8n backup directory not found: $n8n_backup_dir"
        return
    fi

    # Find all date-based subfolders (format: YYYY-MM-DD)
    date_folders=$(find "$n8n_backup_dir" -maxdepth 1 -type d -name "????-??-??" | sort)

    if [[ -z "$date_folders" ]]; then
        log "No date-based subfolders found in $n8n_backup_dir"
    else
        for folder in $date_folders; do
            folder_name=$(basename "$folder")
            zip_file="$n8n_backup_dir/${folder_name}_backups.zip"

            # Skip if folder is already compressed
            if [[ -f "$zip_file" ]]; then
                # Check if zip file is newer than folder contents
                newer_files=$(find "$folder" -type f -newer "$zip_file" 2>/dev/null | wc -l)
                if [[ $newer_files -eq 0 ]]; then
                    log "Zip file already exists and up to date for $folder_name, skipping: $zip_file"
                    continue
                fi
            fi

            log "Zipping subfolder: $folder_name"
            file_count=$(find "$folder" -type f | wc -l)
            log "Found $file_count files to compress in $folder_name"

            if [[ "$dry_run" == "false" ]]; then
                # Create zip file from the folder contents
                if (cd "$n8n_backup_dir" && zip -r "${folder_name}_backups.zip" "$folder_name"); then
                    zip_size=$(du -h "$zip_file" | cut -f1)
                    log "Successfully created zip archive: $zip_file (Size: $zip_size)"

                    # Remove the original folder
                    rm -rf "$folder"
                    log "Removed original subfolder: $folder_name"
                else
                    log "Error: Failed to create zip archive for $folder_name"
                fi
            else
                log "[DRY RUN] Would compress: $folder to $zip_file"
                log "[DRY RUN] Would remove: $folder"
            fi
        done
    fi
}

# Function to cleanup old backups
cleanup_old_backups() {
    log "Cleaning up backups older than $days_to_keep days..."

    # Clean PostgreSQL backups
    if [[ -d "$postgres_backup_dir" ]]; then
        databases=($(get_databases_from_backups "$postgres_backup_dir"))

        for database in "${databases[@]}"; do
            log "Cleaning up old backups for database: $database"

            # Remove old compressed archives
            find "$postgres_backup_dir" -name "${database}_*.tar.gz" -type f -mtime "+$days_to_keep" | while read -r archive; do
                log "Removing old compressed backup: $(basename "$archive")"
                if [[ "$dry_run" == "false" ]]; then
                    rm "$archive"
                else
                    log "[DRY RUN] Would remove: $archive"
                fi
            done

            # Remove old uncompressed directories
            find "$postgres_backup_dir" -name "${database}_*" -type d -mtime "+$days_to_keep" | while read -r dir; do
                log "Removing old uncompressed backup directory: $(basename "$dir")"
                if [[ "$dry_run" == "false" ]]; then
                    rm -rf "$dir"
                else
                    log "[DRY RUN] Would remove: $dir"
                fi
            done

            # Remove old individual compressed SQL files
            find "$postgres_backup_dir" -name "${database}_*.sql.gz" -type f -mtime "+$days_to_keep" | while read -r sql_gz; do
                log "Removing old compressed SQL file: $(basename "$sql_gz")"
                if [[ "$dry_run" == "false" ]]; then
                    rm "$sql_gz"
                else
                    log "[DRY RUN] Would remove: $sql_gz"
                fi
            done
        done
    fi

    # Clean n8n backups
    if [[ -d "$n8n_backup_dir" ]]; then
        log "Cleaning up old n8n backups..."

        # Remove old zip files
        find "$n8n_backup_dir" -name "*_backups.zip" -type f -mtime "+$days_to_keep" | while read -r zip_file; do
            log "Removing old n8n backup: $(basename "$zip_file")"
            if [[ "$dry_run" == "false" ]]; then
                rm "$zip_file"
            else
                log "[DRY RUN] Would remove: $zip_file"
            fi
        done

        # Remove old date folders (shouldn't exist if compression worked, but just in case)
        find "$n8n_backup_dir" -name "????-??-??" -type d -mtime "+$days_to_keep" | while read -r folder; do
            log "Removing old n8n backup folder: $(basename "$folder")"
            if [[ "$dry_run" == "false" ]]; then
                rm -rf "$folder"
            else
                log "[DRY RUN] Would remove: $folder"
            fi
        done
    fi

    # Clean up empty directories
    if [[ "$dry_run" == "false" ]]; then
        find "$base_dir" -type d -empty -delete 2>/dev/null || true
    fi
}

# Function to generate archive report
generate_archive_report() {
    local report_file="$base_dir/archive_report_$(date +%Y%m%d_%H%M%S).txt"

    echo "=== ARCHIVE REPORT ===" > "$report_file"
    echo "Generated: $(date)" >> "$report_file"
    echo "Base directory: $base_dir" >> "$report_file"
    echo "Days to keep: $days_to_keep" >> "$report_file"
    echo "" >> "$report_file"

    # PostgreSQL backups summary
    echo "=== POSTGRESQL BACKUPS ===" >> "$report_file"
    if [[ -d "$postgres_backup_dir" ]]; then
        databases=($(get_databases_from_backups "$postgres_backup_dir"))
        echo "Databases found: ${#databases[@]}" >> "$report_file"

        for database in "${databases[@]}"; do
            echo "" >> "$report_file"
            echo "Database: $database" >> "$report_file"

            # Count compressed archives
            compressed_count=0
            while IFS= read -r file; do
                [[ -f "$file" ]] && ((compressed_count++))
            done < <(find "$postgres_backup_dir" -name "${database}_*.tar.gz" -type f)
            echo "  Compressed archives: $compressed_count" >> "$report_file"

            # List them with sizes
            find "$postgres_backup_dir" -name "${database}_*.tar.gz" -type f -exec du -h {} \; | sort -hr | while read -r size file; do
                echo "    $(basename "$file") - $size" >> "$report_file"
            done

            # Count uncompressed directories
            uncompressed_count=0
            while IFS= read -r dir; do
                [[ -d "$dir" ]] && ((uncompressed_count++))
            done < <(find "$postgres_backup_dir" -name "${database}_*" -type d)
            echo "  Uncompressed directories: $uncompressed_count" >> "$report_file"

            # List them with sizes
            find "$postgres_backup_dir" -name "${database}_*" -type d -exec du -sh {} \; | sort -hr | while read -r size dir; do
                echo "    $(basename "$dir") - $size" >> "$report_file"
            done
        done
    else
        echo "No PostgreSQL backup directory found" >> "$report_file"
    fi

    # n8n backups summary
    echo "" >> "$report_file"
    echo "=== N8N BACKUPS ===" >> "$report_file"
    if [[ -d "$n8n_backup_dir" ]]; then
        zip_count=0
        while IFS= read -r file; do
            [[ -f "$file" ]] && ((zip_count++))
        done < <(find "$n8n_backup_dir" -name "*_backups.zip" -type f)
        echo "Compressed zip files: $zip_count" >> "$report_file"

        find "$n8n_backup_dir" -name "*_backups.zip" -type f -exec du -h {} \; | sort -hr | while read -r size file; do
            echo "  $(basename "$file") - $size" >> "$report_file"
        done

        folder_count=0
        while IFS= read -r dir; do
            [[ -d "$dir" ]] && ((folder_count++))
        done < <(find "$n8n_backup_dir" -name "????-??-??" -type d)
        echo "Uncompressed folders: $folder_count" >> "$report_file"

        find "$n8n_backup_dir" -name "????-??-??" -type d -exec du -sh {} \; | sort -hr | while read -r size dir; do
            echo "  $(basename "$dir") - $size" >> "$report_file"
        done
    else
        echo "No n8n backup directory found" >> "$report_file"
    fi

    # Total disk usage
    echo "" >> "$report_file"
    echo "=== DISK USAGE ===" >> "$report_file"
    total_usage=$(du -sh "$base_dir" 2>/dev/null | cut -f1)
    echo "Total backup directory size: ${total_usage:-N/A}" >> "$report_file"

    log "Archive report generated: $report_file"
}

# Main execution
main() {
    log "Starting archive process..."

    # Create directories if they don't exist
    if [[ "$dry_run" == "false" ]]; then
        mkdir -p "$postgres_backup_dir"
        mkdir -p "$n8n_backup_dir"
    fi

    # Process PostgreSQL backups
    if [[ "$compress_sql" == "true" ]]; then
        compress_postgres_sql_files
    else
        log "Skipping PostgreSQL compression (--compress-sql not set)"
    fi

    # Process n8n backups
    if [[ "$compress_n8n" == "true" ]]; then
        compress_n8n_backups
    else
        log "Skipping n8n compression (--compress-n8n not set)"
    fi

    # Cleanup old backups
    cleanup_old_backups

    # Generate report
    generate_archive_report

    log "Archive process completed"
}

# Run main function
main