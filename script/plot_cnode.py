import pandas as pd
import matplotlib.pyplot as plt

### --- 그래프 설정 --- ###
# 분석할 CSV 파일 이름
CSV_FILE_PATH = "simulation_performance.csv"
# 그래프로 그릴 데이터 컬럼 이름
COLUMN_TO_PLOT = "avg_cnode_time"
# Y축 최소값 설정
Y_AXIS_MIN = 0.1
# Y축 최대값 설정
Y_AXIS_MAX = 3.0
# 저장할 그래프 이미지 파일 이름
OUTPUT_FILENAME = "avg_cnode_time_graph.png"
### -------------------- ###


def plot_custom_graph(csv_path, column, y_min, y_max, output_filename):
    """
    CSV 파일에서 지정된 컬럼 데이터를 읽어 Y축 범위를 설정하여 그래프를 생성합니다.
    """
    # 1. CSV 파일 읽기
    try:
        df = pd.read_csv(csv_path)
    except FileNotFoundError:
        print(f"오류: '{csv_path}' 파일을 찾을 수 없습니다. 스크립트와 같은 폴더에 파일이 있는지 확인하세요.")
        return
    except Exception as e:
        print(f"파일을 읽는 중 오류가 발생했습니다: {e}")
        return

    # 2. 필요한 컬럼이 있는지 확인
    if 'round_id' not in df.columns or column not in df.columns:
        print(f"오류: CSV 파일에 'round_id' 또는 '{column}' 컬럼이 존재하지 않습니다.")
        return

    # 3. 그래프 생성
    plt.figure(figsize=(12, 7))
    
    plt.plot(df['round_id'], df[column], 
             marker='o', 
             linestyle='-', 
             color='teal', 
             label=column)

    # 4. 그래프 스타일 및 정보 설정
    plt.title(f'Performance of C-node submit Score per Round', fontsize=16)
    plt.xlabel('Round', fontsize=12)
    plt.ylabel('Time (s)', fontsize=12)
    plt.grid(True, which='both', linestyle='--', linewidth=0.5)
    # 평균값 라인
    plt.axhline(y=df[column].mean(), color='r', linestyle='--', label='Average')
    # 평균값 표시
    plt.text(1.8, df[column].mean() + 0.05, f'Avg: {df[column].mean():.2f}', color='r', fontsize=10)
    
    # 5. Y축 범위 설정 (사용자 지정)
    plt.ylim(y_min, y_max)
    
    plt.legend()
    plt.tight_layout()

    # 6. 그래프 저장 및 출력
    try:
        plt.savefig(output_filename)
        print(f"그래프 '{output_filename}'가 성공적으로 저장되었습니다.")
        plt.show()
    except Exception as e:
        print(f"그래프를 저장하는 중 오류가 발생했습니다: {e}")


# --- 메인 실행 블록 ---
if __name__ == "__main__":
    plot_custom_graph(
        csv_path=CSV_FILE_PATH,
        column=COLUMN_TO_PLOT,
        y_min=Y_AXIS_MIN,
        y_max=Y_AXIS_MAX,
        output_filename=OUTPUT_FILENAME
    )

