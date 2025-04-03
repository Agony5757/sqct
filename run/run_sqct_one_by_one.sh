#!/bin/bash

# --- Configuration ---
m=21                                      # Set m here (n = 2^m)
n=$((2**m))                              # Calculate n
maxK=$((2**(m-1)))                        # Calculate max K (exclusive upper bound for k ranges)
NUM_K_PER_JOB=512                          # !!! NEW: Number of k values (odd ones) per job !!!
MAX_JOBS=128                              # Maximum number of jobs to submit
CONFIG_DIR="configs"                     # Directory for temporary config files
EXECUTABLE="./sqct"                      # Path to your executable
SOURCE_EXECUTABLE="../build/sqct"        # Source path of the executable
LOG_DIR="logs"                           # Directory to store PBS log files
OUTPUT_DIR="out"                         # Directory for output files
ACCOUNT="sqct"                           # !!! REPLACE with your project/account string !!!
WALLTIME_PER_JOB="4800:00:00"            # Max walltime for EACH job (HH:MM:SS)

# Tracking files
TRACKING_FILE_COMPLETED="completed_ids.txt"  # Records successfully completed n_k pairs
touch "$TRACKING_FILE_COMPLETED"            # Ensure file exists
TRACKING_FILE_STARTED="started_ids.txt"      # Records n_k pairs for jobs that have been submitted/started
touch "$TRACKING_FILE_STARTED"            # Ensure file exists

# --- Input Validation ---
if [ "$NUM_K_PER_JOB" -le 0 ]; then
    echo "Error: NUM_K_PER_JOB must be a positive integer."
    exit 1
fi

# --- Copy BFS layer files ---
echo "Checking and copying BFS layer files..."
for i in {0..18}; do
    # Check and copy .ind.bin files
    SRC_IND="../build/bfs-layer-${i}.ind.bin"
    DST_IND="./bfs-layer-${i}.ind.bin"
    if [ -f "$SRC_IND" ] && [ ! -f "$DST_IND" ]; then
        echo "Copying $SRC_IND to $DST_IND"
        cp "$SRC_IND" "$DST_IND"
    fi

    # Check and copy .uni.bin files
    SRC_UNI="../build/bfs-layer-${i}.uni.bin"
    DST_UNI="./bfs-layer-${i}.uni.bin"
    if [ -f "$SRC_UNI" ] && [ ! -f "$DST_UNI" ]; then
        echo "Copying $SRC_UNI to $DST_UNI"
        cp "$SRC_UNI" "$DST_UNI"
    fi
done

# --- Copy executable ---
echo "Copying executable from $SOURCE_EXECUTABLE to $EXECUTABLE"
if [ -f "$SOURCE_EXECUTABLE" ]; then
    cp "$SOURCE_EXECUTABLE" "$EXECUTABLE"
    chmod +x "$EXECUTABLE"  # Ensure it's executable
else
    echo "Error: Source executable '$SOURCE_EXECUTABLE' not found."
    exit 1
fi

# --- Sanity Checks ---
if [ ! -x "$EXECUTABLE" ]; then
    echo "Error: Executable '$EXECUTABLE' not found or not executable."
    exit 1
fi

if [ -z "$ACCOUNT" ] || [ "$ACCOUNT" == "sqct" ]; then # Updated placeholder check
    echo "Warning: ACCOUNT is set to 'sqct'. Please ensure this is your correct project/account string."
    # Consider exiting if it MUST be changed:
    # echo "Error: Please replace 'sqct' with your actual PBS account/project string in the script."
    # exit 1
fi

# Create directories if they don't exist
mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$OUTPUT_DIR"

# Clean up old config files (optional, consider if needed)
# rm -f "$CONFIG_DIR"/config_*.txt

echo "Starting submission process for m=$m (n=$n)"
echo "Max K (exclusive): $maxK"
echo "Number of k values per job: $NUM_K_PER_JOB"
echo "Max jobs to submit: $MAX_JOBS"
echo "Config Dir: $CONFIG_DIR"
echo "Output Dir: $OUTPUT_DIR"
echo "Executable: $EXECUTABLE"
echo "Log Dir:    $LOG_DIR"
echo "Account:    $ACCOUNT"
echo "Walltime:   $WALLTIME_PER_JOB (per job)"
echo "-------------------------------------"

# --- Main Loop ---
SUBMITTED_COUNT=0
SKIPPED_RANGES_COUNT=0
ERROR_COUNT=0
K_STEP=2 # Step is fixed at 2 (only odd k values)
JOB_K_RANGE_SIZE=$((NUM_K_PER_JOB * K_STEP)) # The span of k values covered by one job

for ((kmin=1; kmin<maxK; kmin+=JOB_K_RANGE_SIZE)); do
    # Break if we've submitted enough jobs
    if [ "$SUBMITTED_COUNT" -ge "$MAX_JOBS" ]; then
        echo "Reached MAX_JOBS limit ($MAX_JOBS). Stopping submission."
        break
    fi

    # Calculate the actual end of the range for this job (exclusive)
    # Ensure kmax_actual does not exceed maxK
    kmax_calc=$((kmin + JOB_K_RANGE_SIZE))
    kmax_actual=$(( kmax_calc < maxK ? kmax_calc : maxK ))

    # Check if *any* k in the current range [kmin, kmax_actual) with step 2 has already been started
    skip_range=false
    ids_in_range=() # Store IDs to add to started/completed files later
    for ((current_k=kmin; current_k<kmax_actual; current_k+=K_STEP)); do
        current_id_str="${n}_${current_k}"
        ids_in_range+=("$current_id_str") # Add to list for later use
        if grep -q "^${current_id_str}$" "$TRACKING_FILE_STARTED"; then
            echo "Skipping range [$kmin, $kmax_actual): ID ${current_id_str} already found in $TRACKING_FILE_STARTED."
            skip_range=true
            break # No need to check further k in this range
        fi
    done

    if $skip_range; then
        ((SKIPPED_RANGES_COUNT++))
        continue # Move to the next range
    fi

    # If we are here, the range is clear to be submitted.
    # Mark all IDs in this range as started *before* submitting
    echo "Marking range [$kmin, $kmax_actual) as started..."
    printf "%s\n" "${ids_in_range[@]}" >> "$TRACKING_FILE_STARTED"

    # Define filenames and job name for the range
    OUTPUT_FILE="$OUTPUT_DIR/uni_${n}_${kmin}_${kmax_actual}.txt"
    CONFIG_FILE="$CONFIG_DIR/config_${n}_${kmin}_${kmax_actual}.txt"
    JOB_NAME="sqct_${n}_${kmin}_${kmax_actual}"
    STDOUT_LOG="${LOG_DIR}/${JOB_NAME}.out"
    STDERR_LOG="${LOG_DIR}/${JOB_NAME}.err"

    # Create config file for the range
    cat > "$CONFIG_FILE" <<EOF
# Request approximation of R_z rotations by angles of the form \\\$2\pi k/n for k in the interval [k1,k2)
UNIFORM
#Filename with approximation results
$OUTPUT_FILE
#Minimal number of T gates to use for approximation
0
#Maximal number of T gates to use for approximation
100
#n
$n
#k1
$kmin
#k2
$kmax_actual
#kstep
$K_STEP
EOF

    # Submit job for the range
    qsub <<EOF
#!/bin/bash
#PBS -N ${JOB_NAME}
#PBS -l select=1:ncpus=1
#PBS -l walltime=${WALLTIME_PER_JOB}
#PBS -A ${ACCOUNT}
#PBS -o ${STDOUT_LOG}
#PBS -e ${STDERR_LOG}
#PBS -j n

echo "PBS Job ID: \$PBS_JOBID"
echo "Running on host: \$(hostname)"
echo "Working directory: \$PBS_O_WORKDIR"
echo "Processing config file: ${CONFIG_FILE}"
echo "Processing k range: [$kmin, $kmax_actual) with step $K_STEP"
echo "Expecting output file: ${OUTPUT_FILE}"

cd "\$PBS_O_WORKDIR" || exit 1
export OMP_NUM_THREADS=1
"${EXECUTABLE}" -G "${CONFIG_FILE}"
EXIT_CODE=\$?

echo "Execution finished with exit code: \$EXIT_CODE"

# If successful, mark all k values in the range as completed
if [ \$EXIT_CODE -eq 0 ]; then
    echo "Job successful. Marking IDs in range [$kmin, $kmax_actual) as completed."
    # Use the list of IDs generated earlier (passed implicitly via the heredoc expansion)
    printf "%s\\n" "${ids_in_range[@]}" >> "\$PBS_O_WORKDIR/${TRACKING_FILE_COMPLETED}"
    echo "Successfully marked ${#ids_in_range[@]} IDs as completed."
else
    echo "Job failed (Exit Code: \$EXIT_CODE). Not marking range [$kmin, $kmax_actual) as completed."
    # Optional: Consider removing from started_ids or adding to a failed_ids list here
    # Be cautious removing from started_ids, as it might cause resubmission attempts.
fi

exit \$EXIT_CODE
EOF

    # Check qsub exit status
    QSUB_EXIT_CODE=$?
    if [ $QSUB_EXIT_CODE -eq 0 ]; then
        ((SUBMITTED_COUNT++))
        num_k_in_job=${#ids_in_range[@]}
        echo "Submitted job $SUBMITTED_COUNT/$MAX_JOBS for k range [$kmin, $kmax_actual) ($num_k_in_job k values)."
    else
        ((ERROR_COUNT++))
        echo "ERROR: qsub failed for k range [$kmin, $kmax_actual) (exit code $QSUB_EXIT_CODE)"
        # If qsub failed, we should ideally remove the IDs we just added to started_ids.txt
        # This is tricky as another process might read the file in between.
        # A safer approach might be just to log the error and manually clean up later if needed.
        echo "Warning: IDs for range [$kmin, $kmax_actual) were added to $TRACKING_FILE_STARTED but qsub failed."
    fi
    sleep 0.5 # Be nice to the scheduler
done

echo "-------------------------------------"
echo "Submission process finished."
echo "Jobs Submitted:       $SUBMITTED_COUNT (Max was $MAX_JOBS)"
echo "Ranges Skipped:       $SKIPPED_RANGES_COUNT (due to existing IDs in $TRACKING_FILE_STARTED)"
echo "Submission Errors:    $ERROR_COUNT"

exit 0
