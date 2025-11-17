#!/bin/bash

# =============================================================================
# 블록체인 TPS 측정 스크립트 v2.1 (수정됨)
# =============================================================================

set -e

# 설정 변수
MAINCHAIN_NODE="tcp://localhost:26658"
MAINCHAIN_BIN="flmainchaind"
SENDER="node0"
DEBUG=true

# 색상 코드
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 로그 함수들
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_debug() { if [ "$DEBUG" = true ]; then echo -e "${YELLOW}[DEBUG]${NC} $1"; fi; }

# 사용법 체크
if [ "$#" -ne 2 ]; then
    echo "사용법: $0 <batch_size> <total_batches>"
    echo "예시: $0 50 5"
    exit 1
fi

BATCH_SIZE=$1
TOTAL_BATCHES=$2
OUTPUT_CSV="tps_results_$(date +%Y%m%d_%H%M%S).csv"

log_info "========================================="
log_info "블록체인 TPS 측정 시작"
log_info "========================================="
log_info "배치 크기: $BATCH_SIZE"
log_info "총 배치 수: $TOTAL_BATCHES"
log_info "출력 파일: $OUTPUT_CSV"

# 블록 높이 조회 함수
get_block_height() {
    local height
    height=$($MAINCHAIN_BIN status --node $MAINCHAIN_NODE 2>/dev/null | \
             grep -o '"latest_block_height":"[0-9]*"' | \
             cut -d'"' -f4)
    
    if [[ ! "$height" =~ ^[0-9]+$ ]]; then
        log_error "블록 높이 조회 실패"
        exit 1
    fi
    
    echo "$height"
}

# 노드 연결 테스트
test_node_connection() {
    log_info "노드 연결 테스트 중..."
    
    if ! $MAINCHAIN_BIN status --node $MAINCHAIN_NODE >/dev/null 2>&1; then
        log_error "노드에 연결할 수 없습니다: $MAINCHAIN_NODE"
        exit 1
    fi
    
    local current_height=$(get_block_height)
    log_success "노드 연결 성공 (현재 블록: $current_height)"
}

# 송신자 계정 확인
check_sender() {
    log_info "송신자 계정 확인 중..."
    
    local sender_addr
    sender_addr=$($MAINCHAIN_BIN keys show $SENDER -a 2>/dev/null || echo "")
    
    if [ -z "$sender_addr" ]; then
        log_error "송신자 키 '$SENDER'를 찾을 수 없습니다"
        exit 1
    fi
    
    log_success "송신자 주소: $sender_addr"
    echo "$sender_addr"
}

# 블록 시간 측정 (수정됨 - 로그를 stderr로 출력)
measure_block_time() {
    log_info "블록 생성 시간 측정 중..." >&2
    
    local start_height=$(get_block_height)
    local start_time=$(date +%s)
    
    log_debug "시작 블록: $start_height" >&2
    printf "블록 대기 중" >&2
    
    local current_height=$start_height
    local timeout_count=0
    
    while [ "$current_height" -eq "$start_height" ] && [ $timeout_count -lt 30 ]; do
        sleep 1
        current_height=$(get_block_height)
        printf "." >&2
        ((timeout_count++))
    done
    echo "" >&2
    
    if [ $timeout_count -ge 30 ]; then
        log_warning "블록 시간 측정 타임아웃. 기본값 5초 사용" >&2
        echo "5"
        return
    fi
    
    local end_time=$(date +%s)
    local block_time=$((end_time - start_time))
    
    log_success "블록 시간: ${block_time}초 ($start_height → $current_height)" >&2
    
    # 숫자만 stdout으로 출력
    echo "$block_time"
}

# 단일 트랜잭션 전송 (수정됨 - fedlearning 사용)
send_transaction() {
    local round=$1
    local tx_id=$2
    
    # 고유한 해시와 이름 생성
    local timestamp=$(date +%s%N 2>/dev/null || date +%s)
    local hash="hash-${round}-${tx_id}-${timestamp}"
    local name="test-${round}-${tx_id}"
    
    log_debug "트랜잭션 전송 시도: $name"
    
    # fedlearning 트랜잭션 사용 (타임아웃 추가)
    local result
    result=$(timeout 10s $MAINCHAIN_BIN tx fedlearning submit-weight 1 "$hash" "$name" \
             --from $SENDER --node $MAINCHAIN_NODE \
             --broadcast-mode=async -y --keyring-backend test 2>&1 || echo "TIMEOUT_ERROR")
    
    local cmd_exit_code=$?
    
    if [ $cmd_exit_code -ne 0 ] || [[ "$result" == *"TIMEOUT_ERROR"* ]]; then
        log_debug "트랜잭션 $tx_id 타임아웃 또는 명령어 실패"
        return 1
    fi
    
    if [[ "$result" == *"error"* ]] || [[ "$result" == *"Error"* ]] || [[ "$result" == *"failed"* ]]; then
        log_debug "트랜잭션 $tx_id 실패: $result"
        return 1
    fi
    
    # txhash 추출
    local txhash
    txhash=$(echo "$result" | grep "^txhash:" | awk '{print $2}' 2>/dev/null || echo "")
    
    if [ -z "$txhash" ]; then
        txhash=$(echo "$result" | grep -oE '[A-F0-9]{64}' | head -1 2>/dev/null || echo "")
    fi
    
    if [ -n "$txhash" ] && [ "$txhash" != "null" ]; then
        log_debug "트랜잭션 $tx_id 성공: $txhash"
        echo "$txhash"
        return 0
    else
        log_debug "txhash 추출 실패. 전체 응답: $result"
        return 1
    fi
}

# 트랜잭션 확인
verify_transaction() {
    local txhash=$1
    
    timeout 5s $MAINCHAIN_BIN query tx --type=hash "$txhash" --node $MAINCHAIN_NODE >/dev/null 2>&1
    return $?
}

# 메인 TPS 측정 함수
run_tps_test() {
    # 초기 설정
    test_node_connection
    local sender_addr=$(check_sender)
    
    # 블록 시간 측정 (수정된 방식)
    log_info "블록 시간 측정 중..."
    local block_time
    block_time=$(measure_block_time)
    local wait_time=$((block_time * 4))
    
    log_info "측정된 블록 시간: ${block_time}초"
    log_info "대기 시간: ${wait_time}초로 설정"
    
    # CSV 헤더 생성
    echo "batch,txs_sent,txs_confirmed,start_height,end_height,send_duration,total_duration,send_tps,confirmed_tps" > "$OUTPUT_CSV"
    
    # 통계 변수
    local total_sent=0
    local total_confirmed=0
    local total_duration=0
    
    # 배치별 실행
    for (( batch=1; batch<=$TOTAL_BATCHES; batch++ )); do
        log_info "==================== 배치 $batch/$TOTAL_BATCHES ===================="
        
        local start_height=$(get_block_height)
        local batch_start_time=$(date +%s)
        local send_start_time=$(date +%s)
        
        # 트랜잭션 배열
        local tx_hashes=()
        local sent_count=0
        
        log_info "트랜잭션 전송 시작..."
        
        # 트랜잭션 전송
        for (( i=1; i<=$BATCH_SIZE; i++ )); do
            log_debug "트랜잭션 $i/$BATCH_SIZE 전송 중..."
            
            local txhash
            if txhash=$(send_transaction "$batch" "$i"); then
                tx_hashes+=("$txhash")
                ((sent_count++))
                log_debug "성공: $txhash"
            else
                log_debug "실패: 트랜잭션 $i"
            fi
            
            # 진행률 표시
            printf "\r[INFO] 진행: $i/$BATCH_SIZE (성공: $sent_count)"
        done
        echo ""
        
        local send_end_time=$(date +%s)
        local send_duration=$((send_end_time - send_start_time))
        
        log_success "전송 완료: $sent_count/$BATCH_SIZE (${send_duration}초)"
        
        if [ $sent_count -eq 0 ]; then
            log_warning "전송된 트랜잭션이 없습니다. 다음 배치로 이동..."
            continue
        fi
        
        # 확정 대기
        log_info "트랜잭션 확정 대기 중... (${wait_time}초)"
        sleep $wait_time
        
        # 트랜잭션 확인
        log_info "트랜잭션 확정 상태 확인 중..."
        local confirmed_count=0
        
        for txhash in "${tx_hashes[@]}"; do
            if verify_transaction "$txhash"; then
                ((confirmed_count++))
            fi
            
            # 간단한 진행률 표시
            printf "."
        done
        echo ""
        
        # 결과 계산
        local batch_end_time=$(date +%s)
        local end_height=$(get_block_height)
        local total_batch_duration=$((batch_end_time - batch_start_time))
        
        local send_tps=0
        local confirmed_tps=0
        
        if [ $send_duration -gt 0 ]; then
            send_tps=$(awk "BEGIN {printf \"%.2f\", $sent_count / $send_duration}")
        fi
        
        if [ $total_batch_duration -gt 0 ]; then
            confirmed_tps=$(awk "BEGIN {printf \"%.2f\", $confirmed_count / $total_batch_duration}")
        fi
        
        # 결과 출력
        log_success "배치 $batch 결과:"
        echo "  ├─ 전송: $sent_count/$BATCH_SIZE"
        echo "  ├─ 확정: $confirmed_count/$sent_count"
        if [ $sent_count -gt 0 ]; then
            echo "  ├─ 확정률: $(awk "BEGIN {printf \"%.1f%%\", ($confirmed_count/$sent_count)*100}")"
        else
            echo "  ├─ 확정률: 0.0%"
        fi
        echo "  ├─ 전송 TPS: $send_tps"
        echo "  ├─ 확정 TPS: $confirmed_tps"
        echo "  ├─ 블록 높이: $start_height → $end_height"
        echo "  └─ 소요 시간: ${total_batch_duration}초"
        
        # CSV 기록
        echo "$batch,$sent_count,$confirmed_count,$start_height,$end_height,$send_duration,$total_batch_duration,$send_tps,$confirmed_tps" >> "$OUTPUT_CSV"
        
        # 누적 통계
        total_sent=$((total_sent + sent_count))
        total_confirmed=$((total_confirmed + confirmed_count))
        total_duration=$((total_duration + total_batch_duration))
    done
    
    # 최종 결과
    log_info "========================================="
    log_info "측정 완료"
    log_info "========================================="
    
    local avg_send_tps=0
    local avg_confirmed_tps=0
    
    if [ $total_duration -gt 0 ]; then
        avg_confirmed_tps=$(awk "BEGIN {printf \"%.2f\", $total_confirmed / $total_duration}")
    fi
    
    if [ -f "$OUTPUT_CSV" ] && [ $total_duration -gt 0 ]; then
        avg_send_tps=$(tail -n +2 "$OUTPUT_CSV" | awk -F, '{sum+=$8; count++} END {if(count>0) printf "%.2f", sum/count; else print "0.00"}')
    fi
    
    echo "📊 최종 결과:"
    echo "  ├─ 총 전송: $total_sent"
    echo "  ├─ 총 확정: $total_confirmed"
    if [ $total_sent -gt 0 ]; then
        echo "  ├─ 전체 확정률: $(awk "BEGIN {printf \"%.1f%%\", ($total_confirmed/$total_sent)*100}")"
    else
        echo "  ├─ 전체 확정률: 0.0%"
    fi
    echo "  ├─ 평균 전송 TPS: $avg_send_tps"
    echo "  ├─ 평균 확정 TPS: $avg_confirmed_tps"
    echo "  └─ 결과 파일: $OUTPUT_CSV"
}

# 메인 실행
main() {
    run_tps_test
}

# 스크립트 실행
main "$@"