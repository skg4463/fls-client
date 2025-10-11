import re
import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.ticker as mticker

# 그래프 1 Y축 범위 설정 (초 단위)
# 예: (0.0, 0.001) => 0 ~ 0.001초 범위, None이면 자동 범위
GRAPH1_Y_RANGE = (0.0, 0.002)  # 0~0.01초로 변경

def parse_log_file(log_path):
    import re
    aggregate_scores_times = {}
    elect_committee_times = {}

    # ANSI 색상 제거: ESC[...m
    ansi_escape_pattern = re.compile(r'\x1b\[[0-9;]*m')

    # 유연한 패턴(중간 토큰 허용)
    pattern_agg = re.compile(r"Phase=\s*AggregateScores-ATT\b.*?\bRound=\s*(\d+)\b.*?\belapsed_time=\s*([\d.]+)")
    pattern_ele = re.compile(r"Phase=\s*ElectNextCommittee\b.*?\bRound=\s*(\d+)\b.*?\belapsed_time=\s*([\d.]+)")

    try:
        with open(log_path, 'r', encoding='utf-8') as f:
            for raw in f:
                cleaned = ansi_escape_pattern.sub('', raw)

                m1 = pattern_agg.search(cleaned)
                if m1:
                    r = int(m1.group(1))
                    sec = float(m1.group(2))  # 초 단위 그대로 사용
                    aggregate_scores_times[r] = sec
                    continue

                m2 = pattern_ele.search(cleaned)
                if m2:
                    r = int(m2.group(1)) - 1  # ElectNextCommittee는 다음 라운드 번호 → 이전 라운드로 매핑
                    if r > 0:
                        sec = float(m2.group(2))  # 초 단위 그대로 사용
                        elect_committee_times[r] = sec
    except FileNotFoundError:
        print(f"오류: '{log_path}' 파일을 찾을 수 없습니다.")
        return [], [], []

    if not aggregate_scores_times:
        print("경고: 'AggregateScores-ATT' 로그를 찾지 못했습니다.")
        return [], [], []

    rounds = sorted(aggregate_scores_times.keys())
    agg_times_sorted = [aggregate_scores_times[r] for r in rounds]
    ele_times_sorted = [elect_committee_times.get(r, 0) for r in rounds]
    return rounds, agg_times_sorted, ele_times_sorted

def read_csv_data(csv_path):
    """CSV 파일을 읽어 데이터프레임으로 반환합니다."""
    try:
        df = pd.read_csv(csv_path)
        return df
    except FileNotFoundError:
        print(f"오류: '{csv_path}' 파일을 찾을 수 없습니다. 스크립트와 같은 폴더에 파일이 있는지 확인하세요.")
        return None

def plot_onchain_logic_time(rounds, agg_times, ele_times):
    """그래프 1: 온체인 로직의 동작 소요 시간을 플롯합니다. (초 단위)"""
    plt.figure(figsize=(12, 7))
    plt.plot(rounds, agg_times, marker='o', linestyle='-', label='AggregateScoresAndCreateATT')
    plt.plot(rounds, ele_times, marker='s', linestyle='--', label='ElectNextCommittee')
    
    plt.title('Execution Time of On-chain Logic', fontsize=16)
    plt.xlabel('Round', fontsize=12)
    plt.ylabel('Time (s)', fontsize=12)
    plt.grid(True, which='both', linestyle='--', linewidth=0.5)
    plt.gca().yaxis.set_major_formatter(mticker.FormatStrFormatter('%.4f'))
    
    # Y축 범위 설정
    if GRAPH1_Y_RANGE is not None:
        plt.ylim(*GRAPH1_Y_RANGE)
    elif agg_times or ele_times:
        vals = (agg_times + ele_times)
        ymin, ymax = min(vals), max(vals)
        pad = max((ymax - ymin) * 0.15, 0.0001)  # 최소 0.1ms 여유
        plt.ylim(max(0.0, ymin - pad), ymax + pad)
    
    plt.legend(fontsize=12)
    plt.tight_layout()
    plt.savefig('1_onchain_logic_time.png')
    print("그래프 '1_onchain_logic_time.png'가 저장되었습니다.")

def plot_submission_time(df):
    """그래프 2: Reed-Solomon 및 트랜잭션 전송 소요 시간을 플롯합니다."""
    plt.figure(figsize=(12, 7))
    plt.plot(df['round_id'], df['avg_lnode_time'], marker='o', linestyle='-', label='L-node submit(avg)')
    plt.plot(df['round_id'], df['global_model_time'], marker='s', linestyle='--', label='CL-node submit')
     # 그래프에 전체 라운드의 평균 시간을 한쪽에 출력, axhline로 그려진 선이 round_id 선의 뒤로 가도록 설정
    plt.axhline(y=df['avg_lnode_time'].mean(), color='blue', linestyle=':', linewidth=1.7, label='Avg L-node submit', zorder=0)
    plt.axhline(y=df['global_model_time'].mean(), color='orange', linestyle=':', linewidth=1.7, label='Avg CL-node submit', zorder=0)
    
   
    # axhline로 그려진 선의 값을 Y축 왼쪽에 텍스트로 표시
    plt.text(df['round_id'].min() - 7.2, df['avg_lnode_time'].mean(), f'Avg: {df["avg_lnode_time"].mean():.4f}s', color='blue', fontsize=10)
    plt.text(df['round_id'].min() - 7.2, df['global_model_time'].mean(), f'Avg: {df["global_model_time"].mean():.4f}s', color='orange', fontsize=10)

    plt.title('Time for Reed-Solomon and Transaction Submission', fontsize=16)
    plt.xlabel('Round', fontsize=12)
    plt.ylabel('Time (s)', fontsize=12)
    plt.grid(True, which='both', linestyle='--', linewidth=0.5)
    
    # Y축 범위 설정
    plt.ylim(0, 3)
    
    plt.gca().yaxis.set_major_formatter(mticker.FormatStrFormatter('%.4f'))
    plt.legend(fontsize=12)
    plt.tight_layout()
    plt.savefig('2_submission_time.png')
    print("그래프 '2_submission_time.png'가 저장되었습니다.")

def plot_total_process_time(df):
    """그래프 3: 학습 체인의 프로세스 총 소요 시간을 플롯합니다."""
    df['total_time'] = df['avg_lnode_time'] + df['avg_cnode_time'] + df['att_aggregation_time'] + df['global_model_time'] - 2
    
    plt.figure(figsize=(12, 7))
    plt.plot(df['round_id'], df['total_time'], marker='o', linestyle='-', color='purple', label='Total Process Time')
    # att_aggregation_time을 함께 플롯
    plt.plot(df['round_id'], df['att_aggregation_time']-2, marker='s', linestyle='--', color='green', label='On-chain overhead')
    # att_aggregation_time의 평균시간 선
    plt.axhline(y=(df['att_aggregation_time']-2).mean(), color='green', linestyle=':', label='Avg On-chain overhead')
    plt.text(df['round_id'].min() - 7.2, (df['att_aggregation_time']-2).mean(), f'Avg: {(df["att_aggregation_time"]-2).mean():.4f}', color='green', fontsize=10)

    # 그래프에 전체 라운드의 평균 시간을 한쪽에 출력
    plt.axhline(y=df['total_time'].mean(), color='purple', linestyle='--', label='Average Total Time')
    # axhline로 그려진 선의 값을 Y축 왼쪽에 텍스트로 표시 
    plt.text(df['round_id'].min() - 7.2, df['total_time'].mean(), f'Avg: {df["total_time"].mean():.4f}', color='purple', fontsize=10)

    plt.title('Total Process Time of the Cross-chain', fontsize=16)
    plt.xlabel('Round', fontsize=12)
    plt.ylabel('Time (s)', fontsize=12)
    plt.grid(True, which='both', linestyle='--', linewidth=0.5)

    # Y축 범위 설정
    plt.ylim(0, 20)
    
    plt.gca().yaxis.set_major_formatter(mticker.FormatStrFormatter('%.4f'))
    plt.legend(fontsize=12)
    plt.tight_layout()
    plt.savefig('3_total_process_time.png')
    print("그래프 '3_total_process_time.png'가 저장되었습니다.")

# --- 메인 실행 블록 ---
if __name__ == "__main__":
    # 경로 확인: 스크립트 폴더에서 실행하지 않는 경우 절대경로나 상대경로 조정
    log_file_path = "./ATTlog.log"  # 또는 "./ATTlog.log" (실행 위치에 맞게 조정)
    csv_file_path = "simulation_performance.csv"

    # 그래프 1 생성
    rounds, agg_times, ele_times = parse_log_file(log_file_path)
    if rounds:
        plot_onchain_logic_time(rounds, agg_times, ele_times)
    
    # CSV 데이터 읽기
    simulation_df = read_csv_data(csv_file_path)
    if simulation_df is not None:
        # 그래프 2 생성
        plot_submission_time(simulation_df)
        
        # 그래프 3 생성
        plot_total_process_time(simulation_df)
    
        # 모든 그래프를 화면에 표시
        plt.show()
