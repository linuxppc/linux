#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# CPU-Idle latency selftest enables systematic retrieval and presentation
# of IPI and timer-triggered wake-up latencies for every CPU and available
# system idle state by leveraging the test_cpuidle_latency module.
#
# Author: Pratik R. Sampat  <psampat at linux.ibm.com>
# Author: Aboorva Devarajan <aboorvad at linux.ibm.com>

DISABLE=1
ENABLE=0

LOG=cpuidle_latency.log
MODULE=/lib/modules/$(uname -r)/kernel/arch/powerpc/kernel/test_cpuidle_latency.ko

# Kselftest framework requirement - SKIP code is 4.
ksft_skip=4
exit_status=0

RUN_TIMER_TEST=1
TIMEOUT=1000000
VERBOSE=0

IPI_SRC_CPU=0

helpme() {
    printf "Usage: %s [-h] [-todg args]
	[-h <help>]
	[-s <source cpu for ipi test> (default: 0)]
	[-m <location of the module>]
	[-o <location of the output>]
	[-v <verbose> (execute test across all CPU threads)]
	[-i <run timer tests>]
	\n" "$0"
    exit 2
}

cpu_is_online() {
    local cpu=$1
    if [ ! -f "/sys/devices/system/cpu/cpu$cpu/online" ]; then
        printf "CPU %s: file not found: /sys/devices/system/cpu/cpu%s/online" "$cpu" "$cpu"
        return 0
    fi
    status=$(cat /sys/devices/system/cpu/cpu"$cpu"/online)
    return "$status"
}

check_valid_cpu() {
    local cpu="$1"
    local cpu_count

    cpu_count="$(nproc)" # Get the number of CPUs on the system

    if [[ "$cpu" =~ ^[0-9]+$ ]]; then
        if ((cpu >= 0 && cpu < cpu_count)); then
            cpu_is_online "$cpu"
            online_status=$?
            if [ "$online_status" -eq "1" ]; then
                return 1
            else
                printf "CPU %s is offline." "$cpu"
                return 0
            fi
        fi
    fi
    return 0
}

parse_arguments() {
    while getopts ht:m:s:o:vt:it: arg; do
        case $arg in
        h) # --help
            helpme
            ;;
        m) # --mod-file
            MODULE=$OPTARG
            ;;
        s) #
            IPI_SRC_CPU=$OPTARG
            check_valid_cpu "$IPI_SRC_CPU"
            cpu_status=$?
            if [ "$cpu_status" == "0" ]; then
                printf "%s is an invalid CPU. Exiting.." "$IPI_SRC_CPU"
                exit
            fi
            ;;
        o) # output log files
            LOG=$OPTARG
            ;;
        v) # verbose mode - execute tests across all CPU threads
            VERBOSE=1
            ;;
        i) # run timer tests
            RUN_TIMER_TEST=1
            ;;
        \?)
            helpme
            ;;
        esac
    done
}

ins_mod() {
    debugfs_file=/sys/kernel/debug/powerpc/latency_test/ipi_latency_ns
    # Check if the module is already loaded
    if [ -f "$debugfs_file" ]; then
        printf "Module %s already loaded\n\n" "$MODULE"
        return 0
    fi
    # Try to load the module
    if [ ! -f "$MODULE" ]; then
        printf "%s module does not exist. Exiting\n" "$MODULE"
        exit $ksft_skip
    fi
    printf "Inserting %s module\n\n" "$MODULE"
    insmod "$MODULE"
    if [ $? != 0 ]; then
        printf "Insmod %s failed\n" "$MODULE"
        exit $ksft_skip
    fi
}

compute_average() {
    arr=("$@")
    sum=0
    size=${#arr[@]}
    if [ "$size" == 0 ]; then
        avg=0
        return 1
    fi
    for i in "${arr[@]}"; do
        sum=$((sum + i))
    done
    avg=$((sum / size))
}

# Perform operation on each CPU for the given state
# $1 - Operation: enable (0) / disable (1)
# $2 - State to enable
op_state() {
    for ((cpu = 0; cpu < NUM_CPUS; cpu++)); do
        cpu_is_online "$cpu"
        local cpu_status=$?
        if [ "$cpu_status" == 0 ]; then
            continue
        fi
        echo "$1" >/sys/devices/system/cpu/cpu"$cpu"/cpuidle/state"$2"/disable
    done
}

cpuidle_enable_state() {
    state=$1
    op_state "$ENABLE" "$state"
}

cpuidle_disable_state() {
    state=$1
    op_state "$DISABLE" "$state"
}

# Enable/Disable all stop states for all CPUs
# $1 - Operation: enable (0) / disable (1)
op_cpuidle() {
    for ((state = 0; state < NUM_STATES; state++)); do
        op_state "$1" "$state"
    done
}

extract_state_information() {
    for ((state = 0; state < NUM_STATES; state++)); do
        state_name=$(cat /sys/devices/system/cpu/cpu"$IPI_SRC_CPU"/cpuidle/state"$state"/name)
        state_name_arr+=("$state_name")
    done
}

# Extract latency in microseconds and convert to nanoseconds
extract_latency() {
    for ((state = 0; state < NUM_STATES; state++)); do
        latency=$(($(cat /sys/devices/system/cpu/cpu"$IPI_SRC_CPU"/cpuidle/state"$state"/latency) * 1000))
        latency_arr+=("$latency")
    done
}

# Simple linear search in an array
# $1 - Element to search for
# $2 - Array
element_in() {
    local item="$1"
    shift
    for element in "$@"; do
        if [ "$element" == "$item" ]; then
            return 0
        fi
    done
    return 1
}

# Parse and return a cpuset with ","(individual) and "-" (range) of CPUs
# $1 - cpuset string
parse_cpuset() {
    echo "$1" | awk '/-/{for (i=$1; i<=$2; i++)printf "%s%s",i,ORS;next} {print}' RS=, FS=-
}

extract_core_information() {
    declare -a thread_arr
    for ((cpu = 0; cpu < NUM_CPUS; cpu++)); do
        cpu_is_online "$cpu"
        local cpu_status=$?
        if [ "$cpu_status" == 0 ]; then
            continue
        fi

        siblings=$(cat /sys/devices/system/cpu/cpu"$cpu"/topology/thread_siblings_list)
        sib_arr=()

        for c in $(parse_cpuset "$siblings"); do
            sib_arr+=("$c")
        done

        if [ "$VERBOSE" == 1 ]; then
            core_arr+=("$cpu")
            continue
        fi
        element_in "${sib_arr[0]}" "${thread_arr[@]}"
        if [ $? == 0 ]; then
            continue
        fi
        core_arr+=("${sib_arr[0]}")

        for thread in "${sib_arr[@]}"; do
            thread_arr+=("$thread")
        done
    done

    src_siblings=$(cat /sys/devices/system/cpu/cpu"$IPI_SRC_CPU"/topology/thread_siblings_list)
    for c in $(parse_cpuset "$src_siblings"); do
        first_core_arr+=("$c")
    done
}

# Run the IPI test
# $1 run for baseline - busy cpu or regular environment
# $2 destination cpu
ipi_test_once() {
    dest_cpu=$2
    if [ "$1" = "baseline" ]; then
        # Keep the CPU busy
        taskset -c "$dest_cpu" cat /dev/random >/dev/null &
        task_pid=$!
        # Wait for the workload to achieve 100% CPU usage
        sleep 1
    fi
    taskset -c "$IPI_SRC_CPU" echo "$dest_cpu" >/sys/kernel/debug/powerpc/latency_test/ipi_cpu_dest
    ipi_latency=$(cat /sys/kernel/debug/powerpc/latency_test/ipi_latency_ns)
    src_cpu=$(cat /sys/kernel/debug/powerpc/latency_test/ipi_cpu_src)
    if [ "$1" = "baseline" ]; then
        kill "$task_pid"
        wait "$task_pid" 2>/dev/null
    fi
}

# Incrementally enable idle states one by one and compute the latency
run_ipi_tests() {
    extract_latency
    # Disable idle states for CPUs
    op_cpuidle "$DISABLE"

    declare -a avg_arr
    printf "...IPI Latency Test...\n" | tee -a "$LOG"

    printf "...Baseline IPI Latency measurement: CPU Busy...\n" >>"$LOG"
    printf "%s %10s %12s\n" "SRC_CPU" "DEST_CPU" "IPI_Latency(ns)" >>"$LOG"
    for cpu in "${core_arr[@]}"; do
        cpu_is_online "$cpu"
        local cpu_status=$?
        if [ "$cpu_status" == 0 ]; then
            continue
        fi
        ipi_test_once "baseline" "$cpu"
        printf "%-3s %10s %12s\n" "$src_cpu" "$cpu" "$ipi_latency" >>"$LOG"
        # Skip computing latency average from the source CPU to avoid bias
        element_in "$cpu" "${first_core_arr[@]}"
        if [ $? == 0 ]; then
            continue
        fi
        avg_arr+=("$ipi_latency")
    done
    compute_average "${avg_arr[@]}"
    printf "Baseline Avg IPI latency(ns): %s\n" "$avg" | tee -a "$LOG"

    for ((state = 0; state < NUM_STATES; state++)); do
        unset avg_arr
        printf "...Enabling state: %s...\n" "${state_name_arr[$state]}" >>"$LOG"
        cpuidle_enable_state $state
        printf "%s %10s %12s\n" "SRC_CPU" "DEST_CPU" "IPI_Latency(ns)" >>"$LOG"
        for cpu in "${core_arr[@]}"; do
            cpu_is_online "$cpu"
            local cpu_status=$?
            if [ "$cpu_status" == 0 ]; then
                continue
            fi
            # Running IPI test and logging results
            sleep 1
            ipi_test_once "test" "$cpu"
            printf "%-3s %10s %12s\n" "$src_cpu" "$cpu" "$ipi_latency" >>"$LOG"
            # Skip computing latency average from the source CPU to avoid bias
            element_in "$cpu" "${first_core_arr[@]}"
            if [ $? == 0 ]; then
                continue
            fi
            avg_arr+=("$ipi_latency")
        done

        compute_average "${avg_arr[@]}"
        printf "Expected IPI latency(ns): %s\n" "${latency_arr[$state]}" >>"$LOG"
        printf "Observed Avg IPI latency(ns) - State %s: %s\n" "${state_name_arr[$state]}" "$avg" | tee -a "$LOG"
        cpuidle_disable_state $state
    done
}

# Extract the residency in microseconds and convert to nanoseconds.
# Add 200 ns so that the timer stays for a little longer than the residency
extract_residency() {
    for ((state = 0; state < NUM_STATES; state++)); do
        residency=$(($(cat /sys/devices/system/cpu/cpu"$IPI_SRC_CPU"/cpuidle/state"$state"/residency) * 1000 + 200))
        residency_arr+=("$residency")
    done
}

# Run the Timeout test
# $1 run for baseline - busy cpu or regular environment
# $2 destination cpu
# $3 timeout
timeout_test_once() {
    dest_cpu=$2
    if [ "$1" = "baseline" ]; then
        # Keep the CPU busy
        taskset -c "$dest_cpu" cat /dev/random >/dev/null &
        task_pid=$!
        # Wait for the workload to achieve 100% CPU usage
        sleep 1
    fi
    taskset -c "$dest_cpu" sleep 1
    taskset -c "$dest_cpu" echo "$3" >/sys/kernel/debug/powerpc/latency_test/timeout_expected_ns
    # Wait for the result to populate
    sleep 0.1
    timeout_diff=$(cat /sys/kernel/debug/powerpc/latency_test/timeout_diff_ns)
    src_cpu=$(cat /sys/kernel/debug/powerpc/latency_test/timeout_cpu_src)
    if [ "$1" = "baseline" ]; then
        kill "$task_pid"
        wait "$task_pid" 2>/dev/null
    fi
}

run_timeout_tests() {
    extract_residency
    # Disable idle states for all CPUs
    op_cpuidle "$DISABLE"

    declare -a avg_arr
    printf "\n...Timeout Latency Test...\n" | tee -a "$LOG"

    printf "...Baseline Timeout Latency measurement: CPU Busy...\n" >>"$LOG"
    printf "%s %10s\n" "Wakeup_src" "Baseline_delay(ns)" >>"$LOG"
    for cpu in "${core_arr[@]}"; do
        cpu_is_online "$cpu"
        local cpu_status=$?
        if [ "$cpu_status" == 0 ]; then
            continue
        fi
        timeout_test_once "baseline" "$cpu" "$TIMEOUT"
        printf "%-3s %13s\n" "$src_cpu" "$timeout_diff" >>"$LOG"
        avg_arr+=("$timeout_diff")
    done
    compute_average "${avg_arr[@]}"
    printf "Baseline Avg timeout diff(ns): %s\n" "$avg" | tee -a "$LOG"

    for ((state = 0; state < NUM_STATES; state++)); do
        unset avg_arr
        printf "...Enabling state: %s...\n" "${state_name_arr["$state"]}" >>"$LOG"
        cpuidle_enable_state "$state"
        printf "%s %10s\n" "Wakeup_src" "Delay(ns)" >>"$LOG"
        for cpu in "${core_arr[@]}"; do
            cpu_is_online "$cpu"
            local cpu_status=$?
            if [ "$cpu_status" == 0 ]; then
                continue
            fi
            timeout_test_once "test" "$cpu" "$TIMEOUT"
            printf "%-3s %13s\n" "$src_cpu" "$timeout_diff" >>"$LOG"
            avg_arr+=("$timeout_diff")
        done
        compute_average "${avg_arr[@]}"
        printf "Expected timeout(ns): %s\n" "${residency_arr["$state"]}" >>"$LOG"
        printf "Observed Avg timeout diff(ns) - State %s: %s\n" "${state_name_arr["$state"]}" "$avg" | tee -a "$LOG"
        cpuidle_disable_state "$state"
    done
}

# Function to exit the test if not intended
exit_test() {
    printf "Exiting the test. Test not intended to run.\n"
    exit "$ksft_skip"
}

printf "Running this test enables all CPU idle states by the time it concludes.\n"
printf "Note: This test does not restore previous idle state.\n"

declare -a residency_arr
declare -a latency_arr
declare -a core_arr
declare -a first_core_arr
declare -a state_name_arr

parse_arguments "$@"

rm -f "$LOG"
touch "$LOG"

NUM_CPUS=$(nproc --all)
NUM_STATES=$(ls -1 /sys/devices/system/cpu/cpu"$IPI_SRC_CPU"/cpuidle/ | wc -l)

extract_core_information
extract_state_information

ins_mod "$MODULE"

run_ipi_tests
if [ "$RUN_TIMER_TEST" == "1" ]; then
    run_timeout_tests
fi

# Enable all idle states for all CPUs
op_cpuidle $ENABLE
printf "Removing %s module\n" "$MODULE"
printf "Full Output logged at: %s\n" "$LOG"

if [ -f "$MODULE" ]; then
    rmmod "$MODULE"
fi

exit "$exit_status"
