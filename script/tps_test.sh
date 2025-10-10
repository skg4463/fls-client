#!/bin/bash

# --- 스크립트 안전장치 ---
set -e

# --- 1. 인자 확인: 동시성 수준과 테스트 지속 시간을 인자로 받음 ---
if [ "$#" -ne 2 ]; then
    echo "사용법: ./tps_test.sh <concurrency> <duration_seconds>"
    echo "예시 (초당 100개의 트랜잭션을 30초간 테스트): ./tps_test.sh 100 30"
    exit 1
fi

# --- 설정 ---
CONCURRENCY=$1
DURATION=$2
MAINCHAIN_NODE="tcp://localhost:26658"
MAINCHAIN_BIN="flmainchaind"
SENDER="node0"

# 결과 저장 파일: 동시성 수준에 따라 다른 CSV 파일 이름을 생성.
OUTPUT_CSV="tps_results_concurrency_${CONCURRENCY}.csv"

echo "--- TPS 테스트 시작 ---"
echo "초당 목표 트랜잭션: $CONCURRENCY txs/sec"
echo "테스트 시간: $DURATION 초"
echo "결과 저장 파일: $OUTPUT_CSV"

# --- 2. CSV 파일 헤더 생성 ---
echo "second,actual_tps" > $OUTPUT_CSV

SENDER_ADDR=$($MAINCHAIN_BIN keys show $SENDER -a)
# echo "Faucet에서 테스트 계정($SENDER)으로 자금을 요청합니다..."
# curl -s -X POST -d "{\"address\": \"$SENDER_ADDR\", \"coins\": [\"10000000stake\"]}" http://localhost:4501/credit > /dev/null

echo "트랜잭션 전송을 시작합니다..."

total_txs_sent=0

# --- 3. 메인 루프: 정해진 시간 동안 매초마다 트랜잭션 전송 및 TPS 측정 ---
for (( s=1; s<=$DURATION; s++ )); do
    start_time_sec=$(date +%s.%N)

    # CONCURRENCY 개수만큼의 트랜잭션을 병렬로 전송.
    for (( i=1; i<=$CONCURRENCY; i++ )); do
        (
            HASH=$(echo "$s-$i" | sha256sum | awk '{print $1}')
            $MAINCHAIN_BIN tx fedlearning submit-weight 1 "$HASH" "tps-test-$s-$i" --from $SENDER --node $MAINCHAIN_NODE -y --broadcast-mode=sync > /dev/null 2>&1
        ) &
    done

    # 이번 1초 동안 보낸 모든 트랜잭션이 끝날 때까지 대기.
    wait

    end_time_sec=$(date +%s.%N)
    # 이번 배치를 처리하는 데 걸린 실제 시간 계산.
    duration_sec=$(awk -v start="$start_time_sec" -v end="$end_time_sec" 'BEGIN {print end - start}')

    # --- 핵심 로직: 실제 TPS 계산 ---
    # (처리된 트랜잭션 수 / 실제 소요 시간)으로 초당 처리량 계산.
    actual_tps=$(awk -v txs="$CONCURRENCY" -v time="$duration_sec" 'BEGIN { if (time > 0) print txs / time; else print 0}')

    # CSV 파일에 결과 기록: (현재 초, 실제 TPS)
    echo "$s,$actual_tps" >> $OUTPUT_CSV
    total_txs_sent=$((total_txs_sent + CONCURRENCY))

    printf "Second %2d: Processed %3d transactions in %.2f seconds. (Actual TPS: %.2f)\n" $s $CONCURRENCY $duration_sec $actual_tps

    # 1초 주기를 대략적으로 맞추기 위해, 남은 시간만큼 대기.
    remaining_sleep=$(awk -v dur="$duration_sec" 'BEGIN { s = 1 - dur; if (s > 0) print s; else print 0}')
    sleep $remaining_sleep
done

echo -e "\n--- TPS 테스트 완료 ---"
echo "총 전송된 트랜잭션 수: $total_txs_sent"