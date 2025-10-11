#!/bin/bash

# --- 스크립트 안전장치 ---
# 어떤 명령어든 실패하면 즉시 스크립트를 중단.
set -e

# --- 설정 ---
MAINCHAIN_NODE="tcp://localhost:26658"
MAINCHAIN_BIN="flmainchaind"
SIDECHAIN_BIN="flstoraged"
TOTAL_ROUNDS_TO_RUN=50 # 이번에 실행할 라운드 수
# --- CSV 파일 이름 설정 추가 ---
PERFORMANCE_CSV="simulation_performance.csv"

# --- ANSI 색상 코드 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # 색상 초기화

# --- 0. 오프체인 클라이언트 사전 컴파일 ---
echo -e "${BLUE}Compiling off-chain clients...${NC}"
(cd uploader && go mod tidy && go build -o uploader)
(cd downloader && go mod tidy && go build -o downloader)
echo -e "${GREEN}Clients compiled successfully.${NC}"

# --- CSV 파일 헤더 생성 ---
# 스크립트를 실행할 때마다 CSV 파일을 새로 만듦.
echo "round_id,avg_lnode_time,avg_cnode_time,att_aggregation_time,global_model_time" > $PERFORMANCE_CSV

# --- 헬퍼 함수 ---
# 주소-이름 매핑 생성
function create_addr_map {
    echo -e "\n${BLUE}Creating address-to-name map...${NC}"
    declare -gA ADDR_TO_NAME
    for i in {0..9}; do
        addr=$($MAINCHAIN_BIN keys show "node$i" -a)
        ADDR_TO_NAME[$addr]="node$i"
    done
    echo -e "${GREEN}Map created.${NC}"
}

# --- 1. 현재 라운드 확인 및 자동 초기화 ---
function init_or_get_start_round {
    echo -e "\n${BLUE}Checking for current round...${NC}"
    CURRENT_ROUND_INFO=$($MAINCHAIN_BIN query fedlearning show-current-round --node $MAINCHAIN_NODE -o json 2>/dev/null || true)
    START_ROUND=$(echo "$CURRENT_ROUND_INFO" | jq -r '.current_round.round_id')

    if [ -z "$START_ROUND" ] || [ "$START_ROUND" == "null" ]; then
        echo -e "${YELLOW}No current round found. Initializing Round 1...${NC}"
        START_ROUND=1
        
        declare -a all_addrs
        for i in {0..9}; do all_addrs+=($($MAINCHAIN_BIN keys show "node$i" -a)); done
        ALL_MEMBERS=$(IFS=,; echo "${all_addrs[*]}")
        INITIAL_C_NODES=$(IFS=,; echo "${all_addrs[*]:0:5}")
        
        $MAINCHAIN_BIN tx fedlearning init-round "$ALL_MEMBERS" "$INITIAL_C_NODES" --from node0 --node $MAINCHAIN_NODE -y --broadcast-mode=sync > /dev/null
        sleep 6 # 초기화 트랜잭션이 블록에 포함될 시간을 줌
        echo -e "${GREEN}Round 1 initialized.${NC}"
    else
        echo -e "${GREEN}Found existing round. Starting simulation from Round $START_ROUND.${NC}"
    fi
    eval "$1=$START_ROUND"
}

# --- 메인 실행 ---
create_addr_map
init_or_get_start_round START_ROUND

# --- 메인 시뮬레이션 루프 ---
for (( round_id=$START_ROUND; round_id<=$START_ROUND+$TOTAL_ROUNDS_TO_RUN-1; round_id++ )); do
    # 라운드별 성능 데이터를 저장할 변수 초기화
    ROUND_AVG_LNODE_TIME=0; ROUND_AVG_CNODE_TIME=0; ROUND_ATT_AGG_TIME=0; ROUND_GLOBAL_MODEL_TIME=0

    echo -e "\n${YELLOW}#####################################################${NC}"
    echo -e "${YELLOW}### STARTING ROUND $round_id"
    echo -e "${YELLOW}#####################################################${NC}\n"
    sleep 2

    echo -e "${BLUE}Fetching participants for Round $round_id...${NC}"
    ROUND_INFO=$($MAINCHAIN_BIN query fedlearning show-round $round_id --node $MAINCHAIN_NODE -o json)
    L_NODES_ADDRS=($(echo "$ROUND_INFO" | jq -r '.round.required_l_nodes[]'))
    C_NODES_ADDRS=($(echo "$ROUND_INFO" | jq -r '.round.required_c_nodes[]'))
    
    echo "L-Nodes for this round: ${#L_NODES_ADDRS[@]}"
    echo "C-Nodes for this round: ${#C_NODES_ADDRS[@]}"
    echo -e "${GREEN}Committee members:${NC}"
    is_cl=true
    for addr in "${C_NODES_ADDRS[@]}"; do
        if [ "$is_cl" = true ]; then echo "  - ${ADDR_TO_NAME[$addr]} (CL-Node) ($addr)"; is_cl=false
        else echo "  - ${ADDR_TO_NAME[$addr]} ($addr)"; fi
    done; echo ""

    CURRENT_STATUS=$(echo "$ROUND_INFO" | jq -r '.round.status')
    echo -e "${YELLOW}--- Phase 1: L-node Submissions (status: $CURRENT_STATUS) ---${NC}"
    
    total_lnode_duration=0; lnode_count=0
    declare -A ORIGINAL_HASHES
    for lnode_addr in "${L_NODES_ADDRS[@]}"; do
        start_time_single_lnode=$(date +%s.%N)
        lnode_name=${ADDR_TO_NAME[$lnode_addr]}
        LNODE_ADDR_SIDE=$($SIDECHAIN_BIN keys show $lnode_name -a)
        TAG="$round_id-$lnode_name-flstorage"
        DUMMY_FILE="uploader/dummy_weight_$lnode_name.bin"; dd if=/dev/urandom of="$DUMMY_FILE" bs=1k count=1 status=none
        UPLOAD_OUTPUT=$(./uploader/uploader "$DUMMY_FILE" "$TAG" "$LNODE_ADDR_SIDE")
        ORIGINAL_HASH=$(echo "$UPLOAD_OUTPUT" | grep "Original file hash:" | cut -d' ' -f4)
        ORIGINAL_HASHES[$lnode_addr]=$ORIGINAL_HASH
        $MAINCHAIN_BIN tx fedlearning submit-weight $round_id $ORIGINAL_HASH "$TAG" --from $lnode_name --node $MAINCHAIN_NODE -y > /dev/null 2>&1
        end_time_single_lnode=$(date +%s.%N)
        duration_single_lnode=$(awk -v start="$start_time_single_lnode" -v end="$end_time_single_lnode" 'BEGIN {print end - start}')
        total_lnode_duration=$(awk -v total="$total_lnode_duration" -v current="$duration_single_lnode" 'BEGIN {print total + current}')
        lnode_count=$((lnode_count + 1))
        printf "  - L-node [%-6s] submitted in ${CYAN}%.2f s${NC}. tag: %-25s, originalHash: %.15s...\n" "$lnode_name" "$duration_single_lnode" "$TAG" "$ORIGINAL_HASH"
    done
    
    ROUND_AVG_LNODE_TIME=$(awk -v total="$total_lnode_duration" -v count="$lnode_count" 'BEGIN { if (count > 0) print total / count; else print 0 }')
    printf "${GREEN}L-node phase completed. Average submission time: %.2f seconds.${NC}\n" $ROUND_AVG_LNODE_TIME
    
    echo -e "\n${BLUE}Waiting for round to advance to 'ScoreSubmissionOpen'...${NC}"
    while true; do
        STATUS=$($MAINCHAIN_BIN query fedlearning show-round $round_id --node $MAINCHAIN_NODE -o json | jq -r '.round.status')
        if [ "$STATUS" == "ScoreSubmissionOpen" ]; then echo -e "${GREEN}Status is now $STATUS. Proceeding.${NC}"; break; fi; sleep 1
    done; echo ""

    CURRENT_STATUS=$($MAINCHAIN_BIN query fedlearning show-round $round_id --node $MAINCHAIN_NODE -o json | jq -r '.round.status')
    echo -e "${YELLOW}--- Phase 2: C-node Submissions (status: $CURRENT_STATUS) ---${NC}"
    
    total_cnode_duration=0; cnode_count=0
    for cnode_addr in "${C_NODES_ADDRS[@]}"; do
        start_time_single_cnode=$(date +%s.%N)
        cnode_name=${ADDR_TO_NAME[$cnode_addr]}; SCORED_LNODES_STR=""; SCORES_STR=""
        for lnode_addr in "${!ORIGINAL_HASHES[@]}"; do
            SCORE=$((RANDOM % 21 + 70)); SCORED_LNODES_STR+="$lnode_addr,"; SCORES_STR+="$SCORE,"
        done
        SCORED_LNODES_STR=${SCORED_LNODES_STR%?}; SCORE_STR=${SCORES_STR%?}
        $MAINCHAIN_BIN tx fedlearning submit-score $round_id "$SCORED_LNODES_STR" "$SCORE_STR" --from $cnode_name --node $MAINCHAIN_NODE -y > /dev/null 2>&1
        end_time_single_cnode=$(date +%s.%N)
        duration_single_cnode=$(awk -v start="$start_time_single_cnode" -v end="$end_time_single_cnode" 'BEGIN {print end - start}')
        total_cnode_duration=$(awk -v total="$total_cnode_duration" -v current="$duration_single_cnode" 'BEGIN {print total + current}')
        cnode_count=$((cnode_count + 1))
        printf "  - C-node [%-6s] submitted scores in ${CYAN}%.2f s${NC}.\n" "$cnode_name" "$duration_single_cnode"
    done
    
    ROUND_AVG_CNODE_TIME=$(awk -v total="$total_cnode_duration" -v count="$cnode_count" 'BEGIN { if (count > 0) print total / count; else print 0 }')
    printf "${GREEN}C-node phase completed. Average submission time: %.2f seconds.${NC}\n" $ROUND_AVG_CNODE_TIME
    
    # C-node 제출이 끝난 직후의 시간을 집계 시작 시간으로 기록 (버그 수정).
    start_time_agg=$(date +%s.%N)
    echo -e "\n${BLUE}Waiting for ATT aggregation... (current: ${YELLOW}$CURRENT_STATUS${BLUE})${NC}"
    while true; do
        STATUS=$($MAINCHAIN_BIN query fedlearning show-round $round_id --node $MAINCHAIN_NODE -o json | jq -r '.round.status')
        if [ "$STATUS" == "AggregationComplete" ]; then
            end_time_agg=$(date +%s.%N)
            ROUND_ATT_AGG_TIME=$(awk -v start="$start_time_agg" -v end="$end_time_agg" 'BEGIN {print end - start}')
            printf "${GREEN}ATT aggregation completed in approximately %.2f seconds.${NC}\n" $ROUND_ATT_AGG_TIME
            
            echo -e "${GREEN}Final ATT for Round $round_id:${NC}"
            ATT_JSON=$($MAINCHAIN_BIN query fedlearning show-final-att $round_id --node $MAINCHAIN_NODE -o json)
            length=$(echo "$ATT_JSON" | jq '.final_att.lnode_addresses | length')
            for (( i=0; i<$length; i++ )); do
                addr=$(echo "$ATT_JSON" | jq -r ".final_att.lnode_addresses[$i]"); score=$(echo "$ATT_JSON" | jq -r ".final_att.scores[$i]"); name=${ADDR_TO_NAME[$addr]}
                printf "  - %-6s - Score: %-3s - %s\n" "$name" "$score" "$addr"
            done; break
        fi; sleep 1
    done; echo ""
    
    CL_NODE_ADDR=${C_NODES_ADDRS[0]}; CL_NODE_NAME=${ADDR_TO_NAME[$CL_NODE_ADDR]}
    CURRENT_STATUS=$($MAINCHAIN_BIN query fedlearning show-round $round_id --node $MAINCHAIN_NODE -o json | jq -r '.round.status')
    echo -e "${YELLOW}--- Phase 3: CL-node [$CL_NODE_NAME] Global Model Submission (status: $CURRENT_STATUS) ---${NC}"
    
    start_time_clnode=$(date +%s.%N)
    CL_NODE_ADDR_SIDE=$($SIDECHAIN_BIN keys show $CL_NODE_NAME -a); DUMMY_GLOBAL_FILE="uploader/dummy_global_$round_id.bin"
    dd if=/dev/urandom of="$DUMMY_GLOBAL_FILE" bs=1k count=1 status=none
    UPLOAD_OUTPUT=$(./uploader/uploader "$DUMMY_GLOBAL_FILE" "$round_id-global-flstorage" "$CL_NODE_ADDR_SIDE")
    GLOBAL_HASH=$(echo "$UPLOAD_OUTPUT" | grep "Original file hash:" | cut -d' ' -f4)
    $MAINCHAIN_BIN tx fedlearning submit-global-model $round_id $GLOBAL_HASH --from $CL_NODE_NAME --node $MAINCHAIN_NODE -y > /dev/null 2>&1
    end_time_clnode=$(date +%s.%N)
    
    # awk 문법 오류 수정 및 시간 출력 추가 (버그 수정).
    ROUND_GLOBAL_MODEL_TIME=$(awk -v start="$start_time_clnode" -v end="$end_time_clnode" 'BEGIN {print end - start}')
    printf "  - CL-node submitted global model hash: $GLOBAL_HASH in ${CYAN}%.2f s${NC}.\n" $ROUND_GLOBAL_MODEL_TIME
    
    # --- 라운드 성능 데이터 CSV에 기록 ---
    echo -e "\n${BLUE}Saving performance data for Round $round_id...${NC}"
    echo "$round_id,$ROUND_AVG_LNODE_TIME,$ROUND_AVG_CNODE_TIME,$ROUND_ATT_AGG_TIME,$ROUND_GLOBAL_MODEL_TIME" >> $PERFORMANCE_CSV
    echo -e "${GREEN}Data saved to $PERFORMANCE_CSV${NC}"
    
    echo -e "\n${BLUE}Waiting for next round committee to be elected...${NC}"
    NEXT_ROUND_ID=$((round_id + 1))
    while true; do
        NEXT_COMMITTEE_INFO=$($MAINCHAIN_BIN query fedlearning show-round-committee $NEXT_ROUND_ID --node $MAINCHAIN_NODE -o json 2>/dev/null || true)
        if [ -n "$NEXT_COMMITTEE_INFO" ] && [ "$(echo "$NEXT_COMMITTEE_INFO" | jq -r '.round_committee.members[0]')" != "null" ]; then
            echo -e "${GREEN}Committee for Round $NEXT_ROUND_ID has been elected.${NC}"; break
        fi;
        echo -n "."
        sleep 1
    done; echo ""
done

echo -e "\n${YELLOW}#####################################################${NC}"
echo -e "${YELLOW}### AUTOMATED SIMULATION COMPLETE"
echo -e "${YELLOW}#####################################################${NC}\n"

# --- 5. 자동 검증 --- 스킵
# echo -e "${BLUE}--- Verifying simulation results ---${NC}"
# for (( round_id=$START_ROUND; round_id<=$START_ROUND+$TOTAL_ROUNDS_TO_RUN-1; round_id++ )); do
#     next_round_id=$((round_id + 1))
#     echo -e "\n${YELLOW}--- Verifying Round $round_id -> Round $next_round_id ---${NC}"
#     
#     echo -e "${GREEN}Final ATT for Round $round_id:${NC}"
#     ATT_JSON=$($MAINCHAIN_BIN query fedlearning show-final-att $round_id --node $MAINCHAIN_NODE -o json)
#     length=$(echo "$ATT_JSON" | jq '.final_att.lnode_addresses | length')
#     for (( i=0; i<$length; i++ )); do
#         addr=$(echo "$ATT_JSON" | jq -r ".final_att.lnode_addresses[$i]"); score=$(echo "$ATT_JSON" | jq -r ".final_att.scores[$i]"); name=${ADDR_TO_NAME[$addr]}
#         printf "  - %-6s - Score: %-3s - %s\n" "$name" "$score" "$addr"
#     done
#     
#     echo -e "\n${GREEN}Elected Committee for Round $next_round_id:${NC}"
#     COMMITTEE_JSON=$($MAINCHAIN_BIN query fedlearning show-round-committee $next_round_id --node $MAINCHAIN_NODE -o json)
#     ELECTED_MEMBERS=($(echo "$COMMITTEE_JSON" | jq -r '.round_committee.members[]'))
#     is_cl=true
#     for addr in "${ELECTED_MEMBERS[@]}"; do
#         if [ "$is_cl" = true ]; then echo "  - ${ADDR_TO_NAME[$addr]} (CL-Node) ($addr)"; is_cl=false
#         else echo "  - ${ADDR_TO_NAME[$addr]} ($addr)"; fi
#     done
#     
#     echo "-----------------------------------------------------"
# done