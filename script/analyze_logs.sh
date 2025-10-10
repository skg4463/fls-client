#!/bin/bash

# 메인체인 켜고 컨트롤c 하고 
# flmainchaind start --log_format text &> flmainchain.log &


LOG_FILE=/home/nakhoon/flmainchain/flmainchain.log
FUNCTION_NAME="AggregateScoresAndCreateATT"
OUTPUT_CSV="onchain_performance.csv"

# 파일 존재 여부 확인
if [ ! -f "$LOG_FILE" ]; then
    echo "Error: Log file not found at $LOG_FILE"
    echo "Please make sure the 'flmainchain' is running and logging to the file."
    exit 1
fi

echo "Analyzing log file: $LOG_FILE"
echo "duration_seconds" > $OUTPUT_CSV

# --- 이 부분을 수정합니다 ---
# grep -o '{.*}' 를 추가하여, 각 라인에서 JSON 부분만 추출합니다.
start_times_json=$(grep "PERF_MEASURE_START: $FUNCTION_NAME" $LOG_FILE | grep -o '{.*}')
end_times_json=$(grep "PERF_MEASURE_END: $FUNCTION_NAME" $LOG_FILE | grep -o '{.*}')
# --- 수정 끝 ---

# 추출된 JSON에서 .time 필드를 가져옵니다.
start_times=($(echo "$start_times_json" | jq -r .time))
end_times=($(echo "$end_times_json" | jq -r .time))

total_duration=0; count=0
echo "Analyzing on-chain performance for '$FUNCTION_NAME'..."

# 각 쌍의 시간 차이를 계산하여 CSV에 추가하고 합산
for i in "${!start_times[@]}"; do
    # end_times 배열의 인덱스 유효성 검사
    if [ -z "${end_times[$i]}" ]; then
        continue
    fi
    start_seconds=$(date -d "${start_times[$i]}" +%s.%N)
    end_seconds=$(date -d "${end_times[$i]}" +%s.%N)

    duration=$(awk -v start="$start_seconds" -v end="$end_seconds" 'BEGIN {print end - start}')
    echo "$duration" >> $OUTPUT_CSV

    total_duration=$(awk -v total="$total_duration" -v current="$duration" 'BEGIN {print total + current}')
    count=$((count + 1))
done

if [ $count -gt 0 ]; then
    average_time=$(awk -v total="$total_duration" -v count="$count" 'BEGIN {print total / count}')
    echo "Data saved to $OUTPUT_CSV"
    echo "On-chain execution time for '$FUNCTION_NAME':"
    printf " - Average over %d runs: %.6f seconds\n" $count $average_time
else
    echo "No performance logs found for '$FUNCTION_NAME' in the log file."
fi