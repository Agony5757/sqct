#!/usr/bin/env python

import os
import sys
import math
import shutil
import subprocess
import time
from pathlib import Path

# --- Configuration ---
M = 21                                     # Set m here (n = 2^m)
N = 2**M                                   # Calculate n
MAX_K = 2**(M - 1)                         # Calculate max K (exclusive upper bound)
NUM_K_PER_JOB = 512                        # Number of k values (odd ones) per job
MAX_JOBS = 128                             # Maximum number of jobs to submit
K_STEP = 2                                 # Step for k values (fixed at 2 for odd k)

CONFIG_DIR = Path("configs")               # Directory for temporary config files
EXECUTABLE_NAME = "sqct"                   # Name of the executable
EXECUTABLE_PATH = Path(f"./{EXECUTABLE_NAME}") # Path to use for execution
SOURCE_EXECUTABLE_DIR = Path("../build")   # Source directory of the executable
SOURCE_EXECUTABLE_PATH = SOURCE_EXECUTABLE_DIR / EXECUTABLE_NAME
LOG_DIR = Path("logs")                     # Directory to store PBS log files
OUTPUT_DIR = Path("out")                   # Directory for output files
ACCOUNT = "sqct"                           # !!! REPLACE with your project/account string !!!
WALLTIME_PER_JOB = "4800:00:00"            # Max walltime for EACH job (HH:MM:SS)

# Tracking files
TRACKING_FILE_COMPLETED = Path("completed_ids.txt")
TRACKING_FILE_STARTED = Path("started_ids.txt")

# --- Helper Functions ---

def load_tracked_ids(filepath: Path) -> set:
    """Loads IDs from a tracking file into a set."""
    if not filepath.exists():
        return set()
    try:
        with open(filepath, 'r') as f:
            # Read lines, strip whitespace, filter out empty lines
            return set(line.strip() for line in f if line.strip())
    except IOError as e:
        print(f"Error reading tracking file {filepath}: {e}", file=sys.stderr)
        sys.exit(1)

def append_ids_to_file(filepath: Path, ids_to_add: list):
    """Appends a list of IDs to a file, one ID per line."""
    try:
        with open(filepath, 'a') as f:
            for id_str in ids_to_add:
                f.write(f"{id_str}\n")
    except IOError as e:
        print(f"Error writing to tracking file {filepath}: {e}", file=sys.stderr)
        # Don't exit here, as the main script might handle qsub errors

def generate_pbs_script(job_name, config_file_rel, output_file_rel, kmin, kmax_actual, ids_in_range_list):
    """Generates the content of the PBS submission script."""

    # Generate the lines to write completed IDs within the PBS script
    completed_id_writing_commands = ""
    if ids_in_range_list:
        completed_id_writing_commands = "\n".join([
            f'    echo "{id_str}" >> "$PBS_O_WORKDIR/{TRACKING_FILE_COMPLETED.name}"'
            for id_str in ids_in_range_list
        ])
        completed_id_writing_commands += f'\n    echo "Successfully marked {len(ids_in_range_list)} IDs as completed."'
    else:
         completed_id_writing_commands = '    echo "No IDs in range to mark as completed."'


    # Use python f-string formatting. Be careful with shell variables ($) vs python variables ({})
    # Shell variables need to be escaped ($$) if the f-string processor would otherwise interpret them.
    # Here, $PBS_JOBID, $hostname, $PBS_O_WORKDIR, $EXIT_CODE are shell variables.
    script_content = f"""#!/bin/bash
#PBS -N {job_name}
#PBS -l select=1:ncpus=1
#PBS -l walltime={WALLTIME_PER_JOB}
#PBS -A {ACCOUNT}
#PBS -o {LOG_DIR / (job_name + '.out')}
#PBS -e {LOG_DIR / (job_name + '.err')}
#PBS -j n

echo "PBS Job ID: $PBS_JOBID"
echo "Running on host: $(hostname)"
echo "Working directory: $PBS_O_WORKDIR"
# Use relative paths within the job script as it CWDs
echo "Processing config file: {config_file_rel}"
echo "Processing k range: [{kmin}, {kmax_actual}) with step {K_STEP}"
echo "Expecting output file: {output_file_rel}"

# Important: Change to the submission directory
cd "$PBS_O_WORKDIR" || {{ echo "Failed to cd to $PBS_O_WORKDIR"; exit 1; }}

export OMP_NUM_THREADS=1
# Execute using the relative path within PBS_O_WORKDIR
"./{EXECUTABLE_PATH.name}" -G "{config_file_rel}"
EXIT_CODE=$?

echo "Execution finished with exit code: $EXIT_CODE"

# If successful, mark all k values in the range as completed
if [ $EXIT_CODE -eq 0 ]; then
    echo "Job successful. Marking IDs in range [{kmin}, {kmax_actual}) as completed."
    # Write the IDs one by one
{completed_id_writing_commands}
else
    echo "Job failed (Exit Code: $EXIT_CODE). Not marking range [{kmin}, {kmax_actual}) as completed."
fi

exit $EXIT_CODE
"""
    return script_content

# --- Main Script ---
if __name__ == "__main__":

    # --- Preparations ---
    print("Starting submission process...")

    # Create tracking files if they don't exist
    TRACKING_FILE_COMPLETED.touch(exist_ok=True)
    TRACKING_FILE_STARTED.touch(exist_ok=True)

    # Input Validation
    if NUM_K_PER_JOB <= 0:
        print("Error: NUM_K_PER_JOB must be a positive integer.", file=sys.stderr)
        sys.exit(1)

    # --- Copy BFS layer files ---
    print("Checking and copying BFS layer files...")
    for i in range(19):  # 0 to 18
        for ext in ["ind.bin", "uni.bin"]:
            src_file = SOURCE_EXECUTABLE_DIR / f"bfs-layer-{i}.{ext}"
            dst_file = Path(f"./bfs-layer-{i}.{ext}")
            if src_file.is_file() and not dst_file.exists():
                print(f"Copying {src_file} to {dst_file}")
                try:
                    shutil.copy2(src_file, dst_file) # copy2 preserves metadata like cp -p
                except Exception as e:
                    print(f"Error copying {src_file}: {e}", file=sys.stderr)
                    sys.exit(1)

    # --- Copy executable ---
    print(f"Copying executable from {SOURCE_EXECUTABLE_PATH} to {EXECUTABLE_PATH}")
    if SOURCE_EXECUTABLE_PATH.is_file():
        try:
            shutil.copy2(SOURCE_EXECUTABLE_PATH, EXECUTABLE_PATH)
            EXECUTABLE_PATH.chmod(0o755)  # Ensure it's executable (read/write/execute for user, read/execute for group/others)
        except Exception as e:
            print(f"Error copying or setting permissions for executable: {e}", file=sys.stderr)
            sys.exit(1)
    else:
        print(f"Error: Source executable '{SOURCE_EXECUTABLE_PATH}' not found.", file=sys.stderr)
        sys.exit(1)

    # --- Sanity Checks ---
    if not EXECUTABLE_PATH.is_file() or not os.access(EXECUTABLE_PATH, os.X_OK):
        print(f"Error: Executable '{EXECUTABLE_PATH}' not found or not executable.", file=sys.stderr)
        sys.exit(1)

    if not ACCOUNT or ACCOUNT == "sqct": # Adjusted check
        print(f"Warning: ACCOUNT is set to '{ACCOUNT}'. Please ensure this is your correct project/account string.", file=sys.stderr)
        # Consider exiting if it MUST be changed:
        # print("Error: Please replace 'sqct' with your actual PBS account/project string.", file=sys.stderr)
        # sys.exit(1)

    # Create directories if they don't exist
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    # --- Load existing started IDs ---
    print(f"Loading already started IDs from {TRACKING_FILE_STARTED}...")
    started_ids_set = load_tracked_ids(TRACKING_FILE_STARTED)
    print(f"Found {len(started_ids_set)} previously started IDs.")

    # --- Display Configuration ---
    print("\n--- Configuration ---")
    print(f"m = {M} (n = {N})")
    print(f"Max K (exclusive): {MAX_K}")
    print(f"Number of k values per job (NUM_K_PER_JOB): {NUM_K_PER_JOB}")
    print(f"Max jobs to submit (MAX_JOBS): {MAX_JOBS}")
    print(f"Config Dir: {CONFIG_DIR}")
    print(f"Output Dir: {OUTPUT_DIR}")
    print(f"Executable: {EXECUTABLE_PATH}")
    print(f"Log Dir:    {LOG_DIR}")
    print(f"Account:    {ACCOUNT}")
    print(f"Walltime:   {WALLTIME_PER_JOB} (per job)")
    print("---------------------\n")

    # --- Main Loop ---
    submitted_count = 0
    skipped_ranges_count = 0
    error_count = 0
    job_k_range_size = NUM_K_PER_JOB * K_STEP  # The span of k values covered by one job

    for kmin in range(1, MAX_K, job_k_range_size):
        # Break if we've submitted enough jobs
        if submitted_count >= MAX_JOBS:
            print(f"Reached MAX_JOBS limit ({MAX_JOBS}). Stopping submission.")
            break

        # Calculate the actual end of the range for this job (exclusive)
        kmax_calc = kmin + job_k_range_size
        kmax_actual = min(kmax_calc, MAX_K)

        # Check if *any* k in the current range [kmin, kmax_actual) has already been started
        skip_range = False
        ids_in_range = [] # Store ID strings for this range: ["N_K1", "N_K3", ...]
        ids_to_check_count = 0 # Keep track of how many IDs we expect in this range

        for current_k in range(kmin, kmax_actual, K_STEP):
            ids_to_check_count += 1
            current_id_str = f"{N}_{current_k}"
            ids_in_range.append(current_id_str) # Store all potential IDs first
            if current_id_str in started_ids_set:
                print(f"Skipping range [{kmin}, {kmax_actual}): ID {current_id_str} already found in {TRACKING_FILE_STARTED.name}.")
                skip_range = True
                break # No need to check further k in this range

        if skip_range:
            skipped_ranges_count += 1
            continue # Move to the next range

        # Check if the range was actually empty (shouldn't happen with kmin=1, step>0)
        if not ids_in_range:
             print(f"Warning: Calculated range [{kmin}, {kmax_actual}) resulted in zero IDs. Skipping.")
             skipped_ranges_count += 1
             continue

        # If we are here, the range is clear to be submitted.
        # Mark all IDs in this range as started *before* submitting
        print(f"Marking range [{kmin}, {kmax_actual}) with {len(ids_in_range)} IDs as started...")
        append_ids_to_file(TRACKING_FILE_STARTED, ids_in_range)
        # Also update the in-memory set immediately
        started_ids_set.update(ids_in_range)

        # --- Prepare for Job Submission ---
        # Use relative paths for files inside the job's working directory
        output_filename = f"uni_{N}_{kmin}_{kmax_actual}.txt"
        output_file_rel = OUTPUT_DIR.name / Path(output_filename) # Relative path like "out/uni_..."
        config_filename = f"config_{N}_{kmin}_{kmax_actual}.txt"
        config_file_abs = CONFIG_DIR / config_filename
        config_file_rel = CONFIG_DIR.name / Path(config_filename) # Relative path like "configs/config_..."

        job_name = f"sqct_{N}_{kmin}_{kmax_actual}"

        # Create config file content
        config_content = f"""# Request approximation of R_z rotations by angles of the form \\\$2\pi k/n for k in the interval [k1,k2)
UNIFORM
#Filename with approximation results
{output_file_rel}
#Minimal number of T gates to use for approximation
0
#Maximal number of T gates to use for approximation
100
#n
{N}
#k1
{kmin}
#k2
{kmax_actual}
#kstep
{K_STEP}
"""
        # Write the config file
        try:
            with open(config_file_abs, 'w') as f:
                f.write(config_content)
        except IOError as e:
            print(f"ERROR: Failed to write config file {config_file_abs}: {e}", file=sys.stderr)
            error_count += 1
            # Potentially try to remove the IDs added to started_ids (complex due to races)
            print(f"Warning: IDs for range [{kmin}, {kmax_actual}) were added to {TRACKING_FILE_STARTED.name} but config file creation failed.")
            continue # Skip submission for this range

        # --- Submit Job ---
        pbs_script = generate_pbs_script(job_name, config_file_rel, output_file_rel, kmin, kmax_actual, ids_in_range)

        try:
            # Use subprocess.run to pipe the script content to qsub's stdin
            # Capture stdout/stderr to get the job ID or errors from qsub itself
            process = subprocess.run(
                ['qsub'],
                input=pbs_script,
                text=True,
                check=True, # Raise CalledProcessError if qsub returns non-zero
                capture_output=True,
                encoding='utf-8' # Explicitly set encoding
            )
            submitted_count += 1
            job_id = process.stdout.strip()
            print(f"Submitted job {submitted_count}/{MAX_JOBS} for k range [{kmin}, {kmax_actual}) ({len(ids_in_range)} k values). Job ID: {job_id}")

        except FileNotFoundError:
            print("ERROR: qsub command not found. Is PBS installed and in your PATH?", file=sys.stderr)
            error_count += 1
            print(f"Warning: IDs for range [{kmin}, {kmax_actual}) were added to {TRACKING_FILE_STARTED.name} but qsub command failed.")
            # No more jobs can be submitted if qsub isn't found
            break
        except subprocess.CalledProcessError as e:
            # qsub command executed but returned an error
            print(f"ERROR: qsub failed for k range [{kmin}, {kmax_actual}) (exit code {e.returncode})", file=sys.stderr)
            print(f"  qsub stdout: {e.stdout}", file=sys.stderr)
            print(f"  qsub stderr: {e.stderr}", file=sys.stderr)
            error_count += 1
            print(f"Warning: IDs for range [{kmin}, {kmax_actual}) were added to {TRACKING_FILE_STARTED.name} but qsub submission failed.")
            # Decide whether to continue trying other jobs or stop
            # continue
        except Exception as e:
            # Catch other potential errors during submission
            print(f"ERROR: An unexpected error occurred during qsub for range [{kmin}, {kmax_actual}): {e}", file=sys.stderr)
            error_count += 1
            print(f"Warning: IDs for range [{kmin}, {kmax_actual}) were added to {TRACKING_FILE_STARTED.name} but qsub submission failed.")
            # continue

        # Be nice to the scheduler
        time.sleep(0.5)

    # --- Final Summary ---
    print("\n-------------------------------------")
    print("Submission process finished.")
    print(f"Jobs Submitted:       {submitted_count} (Max was {MAX_JOBS})")
    print(f"Ranges Skipped:       {skipped_ranges_count} (due to existing IDs in {TRACKING_FILE_STARTED.name})")
    print(f"Submission Errors:    {error_count}")
    print("-------------------------------------")

    sys.exit(0)
