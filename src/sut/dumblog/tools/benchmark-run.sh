#!/usr/bin/env bash

set -euo pipefail

# Inspired by: https://sled.rs/perf.html#experimental-design

BENCHMARK_ITERATIONS=2

BENCHMARK_WORKLOAD1="bench-journal"
BENCHMARK_WORKLOAD2="bench-sqlite"

BENCHMARK_GHC_OPTS=("-threaded" "-rtsopts" "-with-rtsopts=-N")
BENCHMARK_CABAL_BUILD_OPTS=("--enable-benchmarks"
                            "--disable-profiling"
                            "-O2"
                            "--ghc-options=${BENCHMARK_GHC_OPTS[*]}")
BENCHMARK_CABAL_RUN_OPTS=("-O2"
                          "--ghc-options=${BENCHMARK_GHC_OPTS[*]}")


# Use the performance governor instead of powersave (for laptops).
for policy in /sys/devices/system/cpu/cpufreq/policy*; do
    echo "${policy}"
    echo "performance" | sudo tee "${policy}/scaling_governor"
done

cabal build "${BENCHMARK_CABAL_BUILD_OPTS[@]}" "${BENCHMARK_WORKLOAD1}"
cabal build "${BENCHMARK_CABAL_BUILD_OPTS[@]}" "${BENCHMARK_WORKLOAD2}"

# Disable turbo boost.
echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo

# Allow for more open file descriptors.
# ulimit -n unlimited

# The following run is just a (CPU) warm up, the results are discarded.
cabal run "${BENCHMARK_CABAL_RUN_OPTS[@]}" "${BENCHMARK_WORKLOAD2}"

declare -a CLIENTS=(5000 6000 7000 8000 9000 10000 11000 12000 13000 14000 15000)

for i in $(seq ${BENCHMARK_ITERATIONS}); do
    # for j in $(seq 6 14); do
    for j in "${CLIENTS[@]}"; do
        cabal run "${BENCHMARK_CABAL_RUN_OPTS[@]}" "${BENCHMARK_WORKLOAD1}" -- \
              ${j} >> "/tmp/${BENCHMARK_WORKLOAD1}-${j}.txt"
        # $((2**${j})) >> "/tmp/${BENCHMARK_WORKLOAD1}-${j}.txt"
        cabal run "${BENCHMARK_CABAL_RUN_OPTS[@]}" "${BENCHMARK_WORKLOAD2}" -- \
              ${j} >> "/tmp/${BENCHMARK_WORKLOAD2}-${j}.txt"
        # $((2**${j})) >> "/tmp/${BENCHMARK_WORKLOAD2}-${j}.txt"
    done
done

# Re-enable turbo boost.
echo 0 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo

# Go back to powersave governor.
for policy in /sys/devices/system/cpu/cpufreq/policy*; do
    echo "${policy}"
    echo "powersave" | sudo tee "${policy}/scaling_governor"
done
