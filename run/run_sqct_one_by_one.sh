#!/bin/bash

# --- Configuration ---
m=21                                      # Set m here (n = 2^m)
n=$((2**m))                              # Calculate n
maxK=$((2**(m-1)))                              # Calculate n
MAX_JOBS=8192                             # Maximum number of jobs to submit
CONFIG_DIR="configs"                     # Directory for temporary config files
EXECUTABLE="./sqct"                      # Path to your executable
SOURCE_EXECUTABLE="../build/sqct"        # Source path of the executable
LOG_DIR="logs"                           # Directory to store PBS log files
OUTPUT_DIR="out"                         # Directory for output files
ACCOUNT="sqct"                           # !!! REPLACE with your project/account string !!!
WALLTIME_PER_JOB="4800:00:00"            # Max walltime for EACH job (HH:MM:SS)

# 在脚本开头添加（配置部分）
TRACKING_FILE_COMPLETED="completed_ids.txt"  # 记录已完成id的文件
touch "$TRACKING_FILE_COMPLETED"            # 确保文件存在
TRACKING_FILE_STARTED="started_ids.txt"  # 记录已完成id的文件
touch "$TRACKING_FILE_STARTED"            # 确保文件存在

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

if [ -z "$ACCOUNT" ] || [ "$ACCOUNT" == "your_actual_project_name" ]; then
    echo "Error: Please replace 'your_actual_project_name' with your actual PBS account/project string in the script."
    exit 1
fi

# Create directories if they don't exist
mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$OUTPUT_DIR"

# Clean up old config files
rm -f "$CONFIG_DIR"/config_*.txt

echo "Starting submission process for m=$m (n=$n)"
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
SKIPPED_COUNT=0
ERROR_COUNT=0

for ((id=1; id<maxK; id+=2)); do
    # Break if we've submitted enough jobs
    if [ "$SUBMITTED_COUNT" -ge "$MAX_JOBS" ]; then
        break
    fi

    if (( id % 2 == 0 )); then
        continue
    fi
    
    # Check if output file exists (silently skip if it does)
    OUTPUT_FILE="$OUTPUT_DIR/uni_${n}_${id}.txt"
    if grep -q "^${n}_${id}$" "$TRACKING_FILE_STARTED"; then
        ((SKIPPED_COUNT++))
        continue
    fi
    
    # Create config file
    CONFIG_FILE="$CONFIG_DIR/config_${n}_${id}.txt"
    cat > "$CONFIG_FILE" <<EOF
# Request approximation of R_z rotations by angles of the form \\$2\pi k/n for k in the interval [k1,k2)
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
$id
#k2
$((id+1))
#kstep
2
EOF
    
    # Submit job
    JOB_NAME="sqct_${n}_${id}"
    STDOUT_LOG="${LOG_DIR}/${JOB_NAME}.out"
    STDERR_LOG="${LOG_DIR}/${JOB_NAME}.err"
    
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
echo "Expecting output file: ${OUTPUT_FILE}"
echo "${n}_${id}" >> "\$PBS_O_WORKDIR/$TRACKING_FILE_STARTED"

cd \$PBS_O_WORKDIR || exit 1
export OMP_NUM_THREADS=1
${EXECUTABLE} -G "${CONFIG_FILE}"
EXIT_CODE=\$?

echo "Execution finished with exit code: \$EXIT_CODE"
echo "${n}_${id}" >> "\$PBS_O_WORKDIR/$TRACKING_FILE_COMPLETED"
exit \$EXIT_CODE
EOF
    
    # Check qsub exit status
    QSUB_EXIT_CODE=$?
    if [ $QSUB_EXIT_CODE -eq 0 ]; then
        ((SUBMITTED_COUNT++))
        echo "Submitted job $SUBMITTED_COUNT/$MAX_JOBS for id=$id"
    else
        ((ERROR_COUNT++))
        echo "ERROR: qsub failed for id=$id (exit code $QSUB_EXIT_CODE)"
    fi
    sleep 0.5
done

echo "-------------------------------------"
echo "Submission complete."
echo "Jobs Submitted: $SUBMITTED_COUNT/$MAX_JOBS"
echo "Jobs Skipped:   $SKIPPED_COUNT"
echo "Submission Errors: $ERROR_COUNT"

exit 0
