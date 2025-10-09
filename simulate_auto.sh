#!/bin/bash

# --- 설정 ---
MAINCHAIN_NODE="tcp://localhost:26658"
MAINCHAIN_BIN="flmainchaind"
SIDECHAIN_BIN="flstoraged"
TOTAL_ROUNDS_TO_RUN=3 # 이번에 실행할 라운드 수

# --- ANSI 색상 코드 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 색상 초기화

# --- 주소-이름 매핑 생성 (로그 가독성을 위해) ---
echo -e "${BLUE}Creating address-to-name map...${NC}"
declare -A ADDR_TO_NAME
for i in {0..9}; do
    addr=$($MAINCHAIN_BIN keys show "node$i" -a)
    ADDR_TO_NAME[$addr]="node$i"
done
echo -e "${GREEN}Map created.${NC}"

# --- 1. 현재 라운드 확인 및 자동 초기화 (버그 수정) ---
echo -e "\n${BLUE}Checking for current round...${NC}"
# -o json 플래그를 추가하고, jq 파서를 snake_case에 맞게 수정
CURRENT_ROUND_INFO=$($MAINCHAIN_BIN query fedlearning show-current-round --node $MAINCHAIN_NODE -o json 2>/dev/null)
START_ROUND=$(echo "$CURRENT_ROUND_INFO" | jq -r '.current_round.round_id')

if [ -z "$START_ROUND" ] || [ "$START_ROUND" == "null" ]; then
    echo -e "${YELLOW}No current round found. Initializing Round 1...${NC}"
    START_ROUND=1
    
    # --- 주소 목록 생성 로직 수정 ---
    declare -a all_addrs
    for i in {0..9}; do
        all_addrs+=($($MAINCHAIN_BIN keys show "node$i" -a))
    done
    ALL_MEMBERS=$(IFS=,; echo "${all_addrs[*]}")
    INITIAL_C_NODES=$(IFS=,; echo "${all_addrs[*]:0:5}")
    # --- 수정 끝 ---
    
    $MAINCHAIN_BIN tx fedlearning init-round "$ALL_MEMBERS" "$INITIAL_C_NODES" --from node0 --node $MAINCHAIN_NODE -y --broadcast-mode=sync > /dev/null
    sleep 6 # 초기화 트랜잭션이 블록에 포함될 시간을 줌
    echo -e "${GREEN}Round 1 initialized.${NC}"
else
    echo -e "${GREEN}Found existing round. Starting simulation from Round $START_ROUND.${NC}"
fi

# --- 메인 시뮬레이션 루프 ---
for (( round_id=$START_ROUND; round_id<$START_ROUND+$TOTAL_ROUNDS_TO_RUN; round_id++ )); do
    echo -e "\n${YELLOW}#####################################################${NC}"
    echo -e "${YELLOW}### STARTING ROUND $round_id"
    echo -e "${YELLOW}#####################################################${NC}\n"
    sleep 2

    # --- 현재 라운드의 L-node 및 C-node 목록 가져오기 ---
    echo -e "${BLUE}Fetching participants for Round $round_id...${NC}"
    ROUND_INFO=$($MAINCHAIN_BIN query fedlearning show-round $round_id --node $MAINCHAIN_NODE -o json)
    L_NODES_ADDRS=($(echo "$ROUND_INFO" | jq -r '.round.required_l_nodes[]'))
    C_NODES_ADDRS=($(echo "$ROUND_INFO" | jq -r '.round.required_c_nodes[]'))
    
    echo "L-Nodes for this round: ${#L_NODES_ADDRS[@]}"
    echo "C-Nodes for this round: ${#C_NODES_ADDRS[@]}"
    echo -e "${GREEN}Committee members:${NC}"
    for addr in "${C_NODES_ADDRS[@]}"; do
        echo "  - ${ADDR_TO_NAME[$addr]} ($addr)"
    done
    echo ""

    # --- L-node 학습 결과 제출 시뮬레이션 ---
    echo -e "${YELLOW}--- Phase 1: L-node Submissions (WeightSubmissionOpen)---${NC}"
    declare -A ORIGINAL_HASHES
    for lnode_addr in "${L_NODES_ADDRS[@]}"; do
        lnode_name=${ADDR_TO_NAME[$lnode_addr]}
        LNODE_ADDR_SIDE=$($SIDECHAIN_BIN keys show $lnode_name -a)
        DUMMY_FILE="dummy_weight_$lnode_name.bin"; dd if=/dev/urandom of="uploader/$DUMMY_FILE" bs=1k count=1 status=none
        
        UPLOAD_OUTPUT=$(cd uploader && go run main.go "./$DUMMY_FILE" "$round_id-$lnode_name-flstorage" "$LNODE_ADDR_SIDE")
        ORIGINAL_HASH=$(echo "$UPLOAD_OUTPUT" | grep "Original file hash:" | cut -d' ' -f4)
        ORIGINAL_HASHES[$lnode_addr]=$ORIGINAL_HASH
        
        $MAINCHAIN_BIN tx fedlearning submit-weight $round_id $ORIGINAL_HASH "$round_id-$lnode_name-flstorage" --from $lnode_name --node $MAINCHAIN_NODE -y > /dev/null 2>&1
        echo "  - L-node [$lnode_name] submitted."
    done
    
    echo -e "\n${BLUE}Waiting for round status to change to 'ScoreSubmissionOpen'...${NC}"
    while true; do
        STATUS=$($MAINCHAIN_BIN query fedlearning show-round $round_id --node $MAINCHAIN_NODE -o json | jq -r '.round.status')
        if [ "$STATUS" == "ScoreSubmissionOpen" ]; then
            echo -e "${GREEN}Status is now ScoreSubmissionOpen. Proceeding to C-node phase.${NC}"
            break
        fi
        sleep 2
    done
    echo ""

    # --- C-node 평가 및 점수 제출 시뮬레이션 ---
    echo -e "${YELLOW}--- Phase 2: C-node Submissions (ScoreSubmissionOpen)---${NC}"
    for cnode_addr in "${C_NODES_ADDRS[@]}"; do
        cnode_name=${ADDR_TO_NAME[$cnode_addr]}
        SCORED_LNODES_STR=""; SCORES_STR=""
        
        for lnode_addr in "${!ORIGINAL_HASHES[@]}"; do
            SCORE=$((RANDOM % 21 + 70))
            SCORED_LNODES_STR+="$lnode_addr,"; SCORES_STR+="$SCORE,"
        done
        
        SCORED_LNODES_STR=${SCORED_LNODES_STR%?}; SCORE_STR=${SCORES_STR%?}
        
        $MAINCHAIN_BIN tx fedlearning submit-score $round_id "$SCORED_LNODES_STR" "$SCORE_STR" --from $cnode_name --node $MAINCHAIN_NODE -y > /dev/null 2>&1
        echo "  - C-node [$cnode_name] submitted scores."
    done
    
    echo -e "\n${BLUE}Waiting for EndBlockers to aggregate ATT...${NC}"
    while true; do
        STATUS=$($MAINCHAIN_BIN query fedlearning show-round $round_id --node $MAINCHAIN_NODE -o json | jq -r '.round.status')
        if [ "$STATUS" == "AggregationComplete" ]; then
            echo -e "${GREEN}Round $round_id is now AggregationComplete.${NC}"
            break
        fi
        sleep 2
    done
    echo ""
    
    # --- CL-node 글로벌 모델 제출 시뮬레이션 ---
    CL_NODE_ADDR=${C_NODES_ADDRS[0]}; CL_NODE_NAME=${ADDR_TO_NAME[$CL_NODE_ADDR]}
    echo -e "${YELLOW}--- Phase 3: CL-node [$CL_NODE_NAME] Global Model Submission ---${NC}"
    
    CL_NODE_ADDR_SIDE=$($SIDECHAIN_BIN keys show $CL_NODE_NAME -a)
    DUMMY_GLOBAL_FILE="dummy_global_$round_id.bin"; dd if=/dev/urandom of="uploader/$DUMMY_GLOBAL_FILE" bs=1k count=1 status=none
    UPLOAD_OUTPUT=$(cd uploader && go run main.go "./$DUMMY_GLOBAL_FILE" "$round_id-global-flstorage" "$CL_NODE_ADDR_SIDE")
    GLOBAL_HASH=$(echo "$UPLOAD_OUTPUT" | grep "Original file hash:" | cut -d' ' -f4)
    
    $MAINCHAIN_BIN tx fedlearning submit-global-model $round_id $GLOBAL_HASH --from $CL_NODE_NAME --node $MAINCHAIN_NODE -y > /dev/null 2>&1
    echo "  - CL-node submitted global model hash: $GLOBAL_HASH"
    
    # --- 다음 라운드 위원회 선출을 기다리는 로직 (sleep 6 대체) ---
    echo -e "\n${BLUE}Waiting for next round committee to be elected...${NC}"
    NEXT_ROUND_ID=$((round_id + 1))
    while true; do
        # 다음 라운드 위원회가 생성되었는지 직접 쿼리하여 확인
        NEXT_COMMITTEE_INFO=$($MAINCHAIN_BIN query fedlearning show-round-committee $NEXT_ROUND_ID --node $MAINCHAIN_NODE -o json 2>/dev/null)
        if [ -n "$NEXT_COMMITTEE_INFO" ] && [ "$(echo "$NEXT_COMMITTEE_INFO" | jq -r '.RoundCommittee.members[0]')" != "null" ]; then
            echo -e "${GREEN}Committee for Round $NEXT_ROUND_ID has been elected.${NC}"
            break
        fi
        echo "Still waiting..."
        sleep 2
    done
done

echo -e "\n${YELLOW}#####################################################${NC}"
echo -e "${YELLOW}### AUTOMATED SIMULATION COMPLETE"
echo -e "${YELLOW}#####################################################${NC}\n"

# --- 5. 자동 검증 ---
echo -e "${BLUE}--- Verifying simulation results ---${NC}"
for (( round_id=$START_ROUND; round_id<$START_ROUND+$TOTAL_ROUNDS_TO_RUN; round_id++ )); do
    next_round_id=$((round_id + 1))
    echo -e "\n${YELLOW}--- Verifying Round $round_id -> Round $next_round_id ---${NC}"
    
    echo -e "${GREEN}Final ATT for Round $round_id:${NC}"
    $MAINCHAIN_BIN query fedlearning show-final-att $round_id --node $MAINCHAIN_NODE
    
    echo -e "\n${GREEN}Elected Committee for Round $next_round_id:${NC}"
    $MAINCHAIN_BIN query fedlearning show-round-committee $next_round_id --node $MAINCHAIN_NODE
    
    echo "-----------------------------------------------------"
done