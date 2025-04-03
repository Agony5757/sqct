#!/bin/bash

# --- Configuration ---
m=5                                      # Set m here (n = 2^m)
n=$((2**m))                              # Calculate n
MAX_JOBS=100                             # Maximum number of jobs to submit
CONFIG_DIR="configs"                     # Directory for temporary config files
EXECUTABLE="./sqct"                      # Path to your executable
SOURCE_EXECUTABLE="../build/sqct"        # Source path of the executable
LOG_DIR="logs"                           # Directory to store PBS log files
OUTPUT_DIR="out"                         # Directory for output files
ACCOUNT="sqct"                           # !!! REPLACE with your project/account string !!!
WALLTIME_PER_JOB="4800:00:00"            # Max walltime for EACH job (HH:MM:SS)

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

if [ -z "$ACCOUNT" ] || [ "$ACCOUNT" == "your_actual_project_name" ]; then
    echo "Error: Please replace 'your_actual_project_name' with your actual PBS account/project string in the script."
    exit 1
fi

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"

echo "Starting submission process..."
echo "Config Dir: $CONFIG_DIR"
echo "Executable: $EXECUTABLE"
echo "Log Dir:    $LOG_DIR"
echo "Account:    $ACCOUNT"
echo "Walltime:   $WALLTIME_PER_JOB (per job)"
echo "-------------------------------------"

# --- Main Loop ---
SUBMITTED_COUNT=0
SKIPPED_COUNT=0
ERROR_COUNT=0

# Use find for potentially better handling of filenames, though ls is fine here too
find "$CONFIG_DIR" -maxdepth 1 -name '*.config' -print0 | while IFS= read -r -d $'\0' CONFIG_FILE; do

    echo "Processing: $CONFIG_FILE"

    # --- Find the expected output filename ---
    # Use grep/tail/sed as before
    OUTPUT_FILE=$(grep -A 1 '^#Filename with approximation results' "${CONFIG_FILE}" | tail -n 1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # Basic check for output file determination
    if [ -z "$OUTPUT_FILE" ] || [[ "$OUTPUT_FILE" == '#'* ]]; then
        echo "  Warning: Could not determine output file from ${CONFIG_FILE}. Skipping submission."
        ((SKIPPED_COUNT++))
        continue # Skip to the next config file
    fi
    echo "  Expected output: $OUTPUT_FILE"

    # --- Check if output file already exists ---
    if [ -f "$OUTPUT_FILE" ]; then
        echo "  Output file '$OUTPUT_FILE' exists. Skipping submission."
        ((SKIPPED_COUNT++))
    else
        echo "  Output file not found. Submitting job..."

        # --- Prepare job details ---
        # Create a unique job name and log filenames based on the config file
        BASENAME=$(basename "$CONFIG_FILE" .config)
        JOB_NAME="sqct_${BASENAME}"
        STDOUT_LOG="${LOG_DIR}/${JOB_NAME}.out"
        STDERR_LOG="${LOG_DIR}/${JOB_NAME}.err"

        # --- Submit the job using qsub and a here-document ---
        # The script inside the here-document will be executed by PBS
        qsub <<EOF
#!/bin/bash
# --- PBS Directives ---
#PBS -N ${JOB_NAME}                      # Job name
#PBS -l select=1:ncpus=1               # Request 1 core on 1 node
#PBS -l walltime=${WALLTIME_PER_JOB}     # Walltime limit for this specific job
#PBS -A ${ACCOUNT}                     # Project/Account string (Using -A as standard)
#PBS -o ${STDOUT_LOG}                  # Standard output file path
#PBS -e ${STDERR_LOG}                  # Standard error file path
#PBS -j n                              # Keep stdout and stderr separate

# --- Job Environment ---
echo "PBS Job ID: \$PBS_JOBID"           # Use \$ to defer expansion until job runs
echo "Running on host: \$(hostname)"
echo "Working directory: \$PBS_O_WORKDIR" # Use \$ for PBS variable
echo "Submitted from: \$(pwd)"           # Shows directory where qsub was run (if needed)
echo "Processing config file: ${CONFIG_FILE}" # This variable is expanded by the submission script
echo "Expecting output file: ${OUTPUT_FILE}" # This variable is expanded by the submission script

# --- Execution ---
# Change to the directory where the submit script was run
cd \$PBS_O_WORKDIR || exit 1 # Exit if cd fails

# Optional: Add a final check inside the job in case of race conditions
# if [ -f "${OUTPUT_FILE}" ]; then
#     echo "Output file '${OUTPUT_FILE}' appeared before execution started. Exiting."
#     exit 0
# fi

echo "Executing command: ${EXECUTABLE} -G ${CONFIG_FILE}"
export OMP_NUM_THREADS=1 # Ensure single-threaded execution
${EXECUTABLE} -G "${CONFIG_FILE}"
EXIT_CODE=\$? # Capture exit code

echo "Execution finished with exit code: \$EXIT_CODE"
exit \$EXIT_CODE # Exit the job script with the executable's exit code

EOF
        # --- Check qsub exit status ---
        QSUB_EXIT_CODE=$?
        if [ $QSUB_EXIT_CODE -eq 0 ]; then
            echo "  Successfully submitted job for ${CONFIG_FILE}"
            ((SUBMITTED_COUNT++))
        else
            echo "  ERROR: qsub command failed with exit code $QSUB_EXIT_CODE for ${CONFIG_FILE}"
            ((ERROR_COUNT++))
        fi
        # Optional: Add a small delay to prevent overwhelming the scheduler
        # sleep 0.2
    fi
    echo "-------------------------------------"
done

echo "Submission complete."
echo "Jobs Submitted: $SUBMITTED_COUNT"
echo "Jobs Skipped:   $SKIPPED_COUNT"
echo "Submission Errors: $ERROR_COUNT"

exit 0

