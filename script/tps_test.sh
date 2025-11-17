#!/bin/bash

set -e

if [ "$#" -ne 2 ]; then
    echo "사용법: ./tps_test.sh <batch_size> <total_batches>"
    echo "예시: ./tps_test.sh 100 10"
    exit 1
fi

BATCH_SIZE=$1
TOTAL_BATCHES=$2
MAINCHAIN_NODE="tcp://localhost:26658"
MAINCHAIN_BIN="flmainchaind"
SENDER="node0"

OUTPUT_CSV="real_tps_results_batch${BATCH_SIZE}_blocks${TOTAL_BATCHES}.csv"

echo "--- 실제 블록체인 TPS 측정 시작 ---"
echo "배치 크기: $BATCH_SIZE txs/batch"
echo "총 배치 수: $TOTAL_BATCHES"

# 안전한 블록 높이 조회 함수 (status 명령어 사용)
get_block_height() {
    local response
    local height
    
    # status 명령어로 블록 높이 조회
    response=$($MAINCHAIN_BIN status --node $MAINCHAIN_NODE 2>/dev/null || echo "ERROR")
    
    if [ "$response" = "ERROR" ]; then
        echo "ERROR: 노드 상태를 가져올 수 없습니다." >&2
        exit 1
    fi
    
    # JSON에서 블록 높이 추출
    height=$(echo "$response" | grep -o '"latest_block_height":"[^"]*"' | cut -d'"' -f4)
    
    if [ -z "$height" ] || ! [[ "$height" =~ ^[0-9]+$ ]]; then
        echo "ERROR: 유효한 블록 높이를 파싱할 수 없습니다. 응답: $height" >&2
        exit 1
    fi
    
    echo "$height"
}

# 블록 타임 자동 측정 (수정된 버전)
echo "블록 생성 간격 측정 중..."
measure_block_time() {
    local start_height=$(get_block_height)
    local start_time=$(date +%s)
    
    echo "현재 블록 높이: $start_height" >&2
    echo "다음 블록을 기다리는 중..." >&2
    
    local current_height=$start_height
    while [ "$current_height" -le "$start_height" ]; do
        sleep 2
        current_height=$(get_block_height)
        printf "." >&2
    done
    echo "" >&2
    
    local end_time=$(date +%s)
    local block_time=$((end_time - start_time))
    echo "블록 생성 시간: ${block_time}초 (높이 $start_height -> $current_height)" >&2
    
    # 숫자만 반환
    echo $block_time
}

BLOCK_TIME=$(measure_block_time)
echo "측정된 블록 시간: $BLOCK_TIME 초"
echo "대기 시간: $((BLOCK_TIME * 3)) 초로 설정"

# CSV 헤더
echo "batch,txs_sent,txs_confirmed,start_height,end_height,duration_sec,actual_tps,block_time_used" > $OUTPUT_CSV

# 송신자 주소 확인
SENDER_ADDR=$($MAINCHAIN_BIN keys show $SENDER -a 2>/dev/null)
if [ -z "$SENDER_ADDR" ]; then
    echo "ERROR: 송신자 키 '$SENDER'를 찾을 수 없습니다."
    exit 1
fi
echo "송신자 주소: $SENDER_ADDR"

# 트랜잭션 전송 테스트
echo "트랜잭션 전송 테스트 중..."
test_hash=$(echo "test-$(date +%s%N)" | sha256sum | awk '{print $1}')
test_result=$($MAINCHAIN_BIN tx fedlearning submit-weight 1 "$test_hash" "test-tx" \
               --from $SENDER --node $MAINCHAIN_NODE -y --broadcast-mode=async 2>&1 || echo "ERROR")

if [ "$test_result" = "ERROR" ] || [[ "$test_result" == *"error"* ]]; then
    echo "ERROR: 트랜잭션 전송 테스트 실패"
    echo "응답: $test_result"
    exit 1
fi
echo "트랜잭션 전송 테스트 성공"

for (( batch=1; batch<=$TOTAL_BATCHES; batch++ )); do
    echo "=== 배치 $batch 시작 ==="
    
    # 시작 블록 높이 기록
    start_height=$(get_block_height)
    start_time=$(date +%s)
    
    # 트랜잭션 해시 저장 배열
    declare -a tx_hashes=()
    
    echo "트랜잭션 전송 중..."
    # 배치 단위로 트랜잭션 전송
    for (( i=1; i<=$BATCH_SIZE; i++ )); do
        HASH=$(echo "$batch-$i-$(date +%s%N)" | sha256sum | awk '{print $1}')
        
        # 트랜잭션 전송 (더 자세한 에러 처리)
        tx_result=$($MAINCHAIN_BIN tx fedlearning submit-weight 1 "$HASH" "tps-test-$batch-$i" \
                   --from $SENDER --node $MAINCHAIN_NODE -y --broadcast-mode=async 2>&1)
        
        # 디버깅: 첫 번째 트랜잭션 응답 출력
        if [ $i -eq 1 ] && [ $batch -eq 1 ]; then
            echo "첫 번째 트랜잭션 응답:" >&2
            echo "$tx_result" >&2
            echo "---" >&2
        fi
        
        # 에러 체크
        if [[ "$tx_result" == *"error"* ]] || [[ "$tx_result" == *"Error"* ]] || [[ "$tx_result" == *"failed"* ]]; then
            if [ $i -le 3 ]; then  # 처음 3개만 에러 출력
                echo "트랜잭션 $i 전송 실패: $tx_result" >&2
            fi
        else
            # YAML 형식에서 트랜잭션 해시 추출 (수정됨)
            tx_hash=$(echo "$tx_result" | grep "^txhash:" | awk '{print $2}')
            
            if [ -z "$tx_hash" ] || [ "$tx_hash" = "null" ]; then
                # 대안 방법: 16진수 해시 패턴 찾기
                tx_hash=$(echo "$tx_result" | grep -oE '[A-F0-9]{64}' | head -1)
            fi
            
            if [ -n "$tx_hash" ] && [ "$tx_hash" != "null" ]; then
                tx_hashes+=("$tx_hash")
                if [ $i -le 3 ] && [ $batch -eq 1 ]; then  # 처음 배치의 첫 3개만 확인
                    echo "트랜잭션 $i 성공: $tx_hash" >&2
                fi
            else
                if [ $i -le 3 ] && [ $batch -eq 1 ]; then
                    echo "트랜잭션 $i 해시 추출 실패" >&2
                fi
            fi
        fi
        
        printf "."
    done
    echo ""
    
    echo "전송된 트랜잭션 수: ${#tx_hashes[@]}"
    
    if [ ${#tx_hashes[@]} -eq 0 ]; then
        echo "경고: 전송된 트랜잭션이 없습니다."
        continue
    fi
    
    # 충분한 확정 대기 시간
    echo "트랜잭션 확정 대기 중... ($((BLOCK_TIME * 3))초)"
    sleep $((BLOCK_TIME * 3))
    
    # 추가로 블록이 실제로 진행되었는지 확인
    current_height=$(get_block_height)
    wait_count=0
    while [ "$current_height" -le "$start_height" ] && [ $wait_count -lt 5 ]; do
        echo "블록이 아직 생성되지 않음. 추가 대기... ($wait_count/5)"
        sleep $BLOCK_TIME
        current_height=$(get_block_height)
        ((wait_count++))
    done
    
    # 종료 시점 측정
    end_time=$(date +%s)
    end_height=$(get_block_height)
    
    # 실제 확정된 트랜잭션 수 확인 (수정된 버전)
    echo "확정 상태 확인 중..."
    confirmed_txs=0
    failed_checks=0

    for tx_hash in "${tx_hashes[@]}"; do
        # 올바른 쿼리 명령어 사용
        if $MAINCHAIN_BIN query tx --type=hash "$tx_hash" --node $MAINCHAIN_NODE >/dev/null 2>&1; then
            ((confirmed_txs++))
        else
            ((failed_checks++))
        fi
        
        # 진행 상황 표시 (매 10개마다)
        total_checked=$((confirmed_txs + failed_checks))
        if [ $((total_checked % 10)) -eq 0 ] && [ $total_checked -gt 0 ]; then
            echo "확인 진행: $total_checked/${#tx_hashes[@]} (확정: $confirmed_txs)"
        fi
    done
    
    # 실제 처리 시간 계산
    duration=$((end_time - start_time))
    
    # 실제 TPS 계산
    if [ $duration -gt 0 ]; then
        actual_tps=$(awk -v confirmed="$confirmed_txs" -v time="$duration" 'BEGIN {printf "%.2f", confirmed/time}')
    else
        actual_tps="0.00"
    fi
    
    # 결과 기록
    echo "$batch,${#tx_hashes[@]},$confirmed_txs,$start_height,$end_height,$duration,$actual_tps,$BLOCK_TIME" >> $OUTPUT_CSV
    
    echo "배치 $batch 완료:"
    echo "  전송: ${#tx_hashes[@]}, 확정: $confirmed_txs"
    if [ ${#tx_hashes[@]} -gt 0 ]; then
        echo "  확정률: $(awk -v conf="$confirmed_txs" -v total="${#tx_hashes[@]}" 'BEGIN {printf "%.1f%%", (conf/total)*100}')"
    else
        echo "  확정률: 0.0%"
    fi
    echo "  소요시간: ${duration}초, TPS: $actual_tps"
    echo "  블록 높이: $start_height -> $end_height (차이: $((end_height - start_height)))"
    echo ""
    
    # 배열 초기화
    unset tx_hashes
done

echo "--- 실제 TPS 측정 완료 ---"
echo "결과 파일: $OUTPUT_CSV"

# 결과 요약
echo ""
echo "=== 측정 결과 요약 ==="
echo "사용된 블록 시간: $BLOCK_TIME 초"
if [ -f "$OUTPUT_CSV" ]; then
    avg_tps=$(tail -n +2 "$OUTPUT_CSV" | awk -F, '{sum+=$6; count++} END {if(count>0) printf "%.2f", sum/count; else print "0.00"}')
    total_confirmed=$(tail -n +2 "$OUTPUT_CSV" | awk -F, '{sum+=$3} END {print sum}')
    echo "평균 TPS: $avg_tps"
    echo "총 확정된 트랜잭션: $total_confirmed"
fi