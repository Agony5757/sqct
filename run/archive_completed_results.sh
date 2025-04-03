#!/bin/bash
# Archive range files (uni_n_kmin_kmax.txt) only if ALL constituent
# k values (odd k in [kmin, kmax)) are listed in completed_ids.txt.

OUTPUT_DIR="out"
COMPLETED_FILE="completed_ids.txt"
ARCHIVE="${OUTPUT_DIR}/2097152.tar" # Changed name for clarity, adjust if needed
TITLE_FILES="${OUTPUT_DIR}/*.title"

echo "Scanning $OUTPUT_DIR for potential range files (uni_*_*_*.txt)..."
echo "Checking completion status against $COMPLETED_FILE..."

# Create temp file list for files to be archived
FILELIST=$(mktemp)
K_STEP=2 # Step used in generation script

# --- Check Completion Status and Build File List ---
# Use find for robust file discovery, especially if many files exist
find "$OUTPUT_DIR" -maxdepth 1 -name 'uni_*_*_*.txt' -print0 | while IFS= read -r -d $'\0' range_file; do
    filename=$(basename "$range_file")

    # Extract n, kmin, kmax from filename: uni_N_KMIN_KMAX.txt
    core_part=${filename#uni_}  # N_KMIN_KMAX.txt
    core_part=${core_part%.txt} # N_KMIN_KMAX

    # Use IFS for robust splitting, handles potential edge cases better than simple cut
    IFS='_' read -r n kmin kmax <<< "$core_part"

    # Basic validation of extracted parts (ensure they look like numbers)
    if ! [[ "$n" =~ ^[0-9]+$ && "$kmin" =~ ^[0-9]+$ && "$kmax" =~ ^[0-9]+$ ]]; then
        echo "Warning: Could not parse n, kmin, kmax from filename '$filename'. Skipping."
        continue
    fi

    # Flag to track if all required IDs for this range file are completed
    all_k_completed=true
    ids_checked_count=0
    missing_ids="" # Keep track of missing IDs for logging

    # Iterate through all the individual k values expected for this range file
    for ((k=kmin; k<kmax; k+=K_STEP)); do
        individual_id="${n}_${k}"
        ids_checked_count=$((ids_checked_count + 1))

        # Check if this specific individual ID exists in the completed file
        # Use -F (fixed string), -x (exact line match), -q (quiet) for efficiency and accuracy
        if ! grep -qxF "$individual_id" "$COMPLETED_FILE"; then
            all_k_completed=false
            missing_ids+="$individual_id "
            # Optional: break early if you only need to know *if* it's incomplete
            # break
        fi
    done

    # Decision: If the file exists AND all its constituent k's are completed AND the range was not empty
    if [[ "$ids_checked_count" -gt 0 && "$all_k_completed" == "true" ]]; then
        if [[ -f "$range_file" ]]; then
            echo "  -> OK: Range file '$filename' exists and all $ids_checked_count constituent IDs found in $COMPLETED_FILE. Adding to archive list."
            # Use printf for safety, ensuring newline separation
            printf "%s\n" "$range_file" >> "$FILELIST"
        else
             echo "  -> Warning: All constituent IDs for '$filename' are completed, but the file itself is missing. Skipping."
        fi
    elif [[ "$ids_checked_count" -eq 0 ]]; then
        echo "  -> Skipping '$filename': Range [$kmin, $kmax) appears empty or invalid (0 IDs checked)."
    else
        # File might exist or not, but it's incomplete
        echo "  -> Skipping '$filename': Not all constituent IDs are complete. Missing: $missing_ids"
    fi
done

# --- Archiving Process ---
if [[ -s "$FILELIST" ]]; then
    num_files=$(wc -l < "$FILELIST")
    echo "-------------------------------------"
    echo "Found $num_files range file(s) ready for archiving (listed in $FILELIST)."
    echo "Target archive: $ARCHIVE"

    # Choose tar action based on archive existence
    if [[ -f "$ARCHIVE" ]]; then
        echo "Updating existing archive..."
        tar_command="tar -uf"
    else
        echo "Creating new archive..."
        tar_command="tar -cf"
    fi

    # Execute tar command using the list of files
    # Using --files-from is efficient for many files
    if $tar_command "$ARCHIVE" --files-from="$FILELIST"; then
        echo "Archive operation successful."
        echo "Removing archived range files..."
        # Read file list line by line for safe removal
        while IFS= read -r file_to_remove; do
             if [[ -f "$file_to_remove" ]]; then # Double-check existence before removing
                 echo "  Removing: $file_to_remove"
                 rm -f "$file_to_remove"
             else
                 echo "  Warning: File already removed or missing: $file_to_remove"
             fi
        done < "$FILELIST"
        echo "Removal complete."
    else
        echo "ERROR: Archive operation failed for $ARCHIVE."
        echo "Original files listed in $FILELIST were NOT removed."
    fi
else
    echo "-------------------------------------"
    echo "No completed range files found meeting the criteria for archiving."
fi

# --- Cleanup ---
# Remove .title files unconditionally (as per original script logic)
echo "-------------------------------------"
echo "Removing any remaining .title files in $OUTPUT_DIR..."
# Use find to check existence before attempting removal to avoid error messages
title_files_found=$(find "$OUTPUT_DIR" -maxdepth 1 -name '*.title' -print -quit)
if [[ -n "$title_files_found" ]]; then
    rm -f "${OUTPUT_DIR}"/*.title
    echo ".title files removed."
else
    echo "No .title files found to remove."
fi

# Remove the temporary file list
rm -f "$FILELIST"
echo "Temporary file list removed. Archiving script finished."
