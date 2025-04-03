#!/usr/bin/env python

import os
import sys
import tarfile
import tempfile
import subprocess
from pathlib import Path
import re # For more robust parsing if needed, though split is likely sufficient

# --- Configuration ---
OUTPUT_DIR = Path("out")
COMPLETED_FILE = Path("completed_ids.txt")
# Use Path object for the archive path
ARCHIVE_PATH = OUTPUT_DIR / "archive_ranges.tar"
TITLE_PATTERN = "*.title" # Pattern for title files within OUTPUT_DIR
K_STEP = 2 # Step used in generation script

# --- Helper Functions ---

def load_completed_ids(filepath: Path) -> set:
    """Loads completed IDs from the tracking file into a set for fast lookups."""
    if not filepath.exists():
        print(f"Warning: Completed IDs file '{filepath}' not found. Assuming no IDs are completed.", file=sys.stderr)
        return set()
    try:
        with open(filepath, 'r') as f:
            return set(line.strip() for line in f if line.strip())
    except IOError as e:
        print(f"Error reading completed IDs file {filepath}: {e}", file=sys.stderr)
        sys.exit(1) # Exit if we can't read the crucial completion file

def check_range_completion(n: int, kmin: int, kmax: int, completed_set: set) -> tuple[bool, list[str]]:
    """
    Checks if all odd k values in the range [kmin, kmax) for a given n
    are present in the completed_set.

    Returns:
        tuple: (bool: True if all complete, list[str]: list of missing IDs)
    """
    missing_ids = []
    if kmin >= kmax: # Handle empty or invalid range
        return False, [] # Consider an empty range not complete for archiving

    for k in range(kmin, kmax, K_STEP):
        individual_id = f"{n}_{k}"
        if individual_id not in completed_set:
            missing_ids.append(individual_id)

    return not missing_ids, missing_ids # Return True if missing_ids list is empty


# --- Main Script ---
if __name__ == "__main__":

    print(f"Scanning {OUTPUT_DIR} for potential range files (uni_*_*_*.txt)...")
    print(f"Checking completion status against {COMPLETED_FILE}...")

    # --- Load Completed IDs ---
    completed_ids_set = load_completed_ids(COMPLETED_FILE)
    print(f"Loaded {len(completed_ids_set)} completed IDs.")

    # --- Find Candidate Files and Check Completion ---
    files_to_archive = []
    files_to_remove_post_archive = [] # Keep track separately for safety

    # Use glob to find potential files
    for range_file_path in OUTPUT_DIR.glob('uni_*_*_*.txt'):
        if not range_file_path.is_file(): # Should be redundant with glob but safe check
            continue

        filename = range_file_path.name

        # Extract n, kmin, kmax from filename
        # Format: uni_N_KMIN_KMAX.txt
        try:
            # Remove prefix and suffix
            core_part = filename.removeprefix('uni_').removesuffix('.txt')
            parts = core_part.split('_')
            if len(parts) != 3:
                raise ValueError("Filename does not match N_KMIN_KMAX format")

            n_str, kmin_str, kmax_str = parts
            n = int(n_str)
            kmin = int(kmin_str)
            kmax = int(kmax_str)

        except (ValueError, IndexError) as e:
            print(f"  Warning: Could not parse n, kmin, kmax from filename '{filename}'. Skipping. Error: {e}")
            continue

        # Check if all constituent k values are marked as completed
        all_complete, missing = check_range_completion(n, kmin, kmax, completed_ids_set)

        # Decision: Archive if the file exists AND all its parts are completed
        if all_complete:
             # We already know range_file_path exists and is a file from the glob/check
            num_ids_expected = (kmax - kmin + K_STEP - 1) // K_STEP # Calculate expected IDs
            print(f"  -> OK: Range file '{filename}' exists and all {num_ids_expected} constituent IDs found in {COMPLETED_FILE.name}. Adding to archive list.")
            files_to_archive.append(range_file_path)
        elif not missing and kmin >= kmax: # Empty range case from check_range_completion
             print(f"  -> Skipping '{filename}': Range [{kmin}, {kmax}) appears empty or invalid.")
        else:
            # File might exist or not, but it's incomplete
            print(f"  -> Skipping '{filename}': Not all constituent IDs are complete. Missing: {' '.join(missing)}")


    # --- Archiving Process ---
    if files_to_archive:
        num_files = len(files_to_archive)
        print("-------------------------------------")
        print(f"Found {num_files} range file(s) ready for archiving.")
        print(f"Target archive: {ARCHIVE_PATH}")

        # Determine tar mode ('w' for write/create, 'a' for append)
        tar_mode = 'a' if ARCHIVE_PATH.exists() else 'w'
        if tar_mode == 'a':
            print("Updating existing archive...")
        else:
            print("Creating new archive...")

        try:
            # Use tarfile for safer archiving
            with tarfile.open(ARCHIVE_PATH, mode=tar_mode) as tar:
                for file_path in files_to_archive:
                    # arcname=file_path.name stores only the filename in the tar
                    # instead of the full path (e.g., stores "uni_....txt" not "out/uni_....txt")
                    print(f"  Adding: {file_path.name}")
                    tar.add(file_path, arcname=file_path.name)

            print("Archive operation successful.")

            # If archive succeeded, prepare list for removal
            files_to_remove_post_archive.extend(files_to_archive)

        except (tarfile.TarError, IOError, OSError) as e:
            print(f"\nERROR: Archive operation failed: {e}", file=sys.stderr)
            print("Original files were NOT marked for removal.")
            # Clear the removal list if archive failed
            files_to_remove_post_archive = []
    else:
        print("-------------------------------------")
        print("No completed range files found meeting the criteria for archiving.")

    # --- Remove Archived Files (only if archive succeeded) ---
    if files_to_remove_post_archive:
        print("Removing archived range files...")
        removed_count = 0
        failed_removal_count = 0
        for file_path in files_to_remove_post_archive:
            try:
                if file_path.exists(): # Check again before removing
                    print(f"  Removing: {file_path}")
                    file_path.unlink()
                    removed_count += 1
                else:
                    print(f"  Warning: File already removed or missing: {file_path}")
            except OSError as e:
                print(f"  ERROR: Failed to remove {file_path}: {e}", file=sys.stderr)
                failed_removal_count += 1
        print(f"Removal complete. Removed: {removed_count}, Failed: {failed_removal_count}.")
        if failed_removal_count > 0:
             print("Warning: Some files intended for removal could not be deleted.", file=sys.stderr)


    # --- Cleanup .title files ---
    print("-------------------------------------")
    print(f"Removing any remaining '{TITLE_PATTERN}' files in {OUTPUT_DIR}...")
    title_files_found = list(OUTPUT_DIR.glob(TITLE_PATTERN))
    if title_files_found:
        removed_count = 0
        failed_count = 0
        for title_file in title_files_found:
            try:
                if title_file.is_file(): # Ensure it's a file before unlinking
                    # print(f"  Removing: {title_file.name}") # Optional verbose logging
                    title_file.unlink()
                    removed_count +=1
            except OSError as e:
                 print(f"  ERROR: Failed to remove {title_file}: {e}", file=sys.stderr)
                 failed_count += 1
        print(f"{removed_count} {TITLE_PATTERN} files removed.")
        if failed_count > 0:
            print(f"Warning: Failed to remove {failed_count} {TITLE_PATTERN} files.", file=sys.stderr)
    else:
        print(f"No {TITLE_PATTERN} files found to remove.")

    print("-------------------------------------")
    print("Archiving script finished.")
