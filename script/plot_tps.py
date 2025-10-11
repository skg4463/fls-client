# plot_tps.py
import pandas as pd
import matplotlib.pyplot as plt
import sys
import glob 

# --- 1. 데이터 파일 로드 ---
# "tps_results_concurrency_..." 패턴과 일치하는 모든 CSV 파일 목록을 찾음.
csv_files = glob.glob('tps_results_concurrency_*.csv')
if not csv_files:
    print("오류: 'tps_results_concurrency_*.csv' 파일을 찾을 수 없습니다.")
    print("먼저 tps_test.sh를 실행해주세요 (예: './tps_test.sh 100 30').")
    sys.exit(1)

# --- 2. 그래프 생성 ---
plt.figure(figsize=(14, 8))

print("\n--- 분석 결과 ---")
# 찾은 각 CSV 파일(각 동시성 수준)에 대해 라인 그래프를 그림.
for file in sorted(csv_files):
    try:
        # 파일 이름에서 동시성 수준(concurrency)을 추출하여 범례(label)로 사용.
        concurrency = file.split('_')[-1].replace('.csv', '')
        data = pd.read_csv(file)

        # 라인 그래프 그리기: x축은 시간(초), y축은 실제 TPS.
        plt.plot(data['second'], data['actual_tps'], marker='o', linestyle='-', label=f'Target Load = {concurrency} tx/sec', linewidth=2.3)
        # 평균값 라인 두께0.95, 색깔은 그래프 선 색깔과 동일하게, 점선으로 표시, 값 텍스트를 라벨)
        plt.axhline(y=data['actual_tps'].mean(), color=plt.gca().lines[-1].get_color(), linestyle='--', linewidth=1.3, label=f'Avg TPS ({concurrency} tx/sec) = {data["actual_tps"].mean():.2f}')


        # 각 테스트의 평균 TPS를 계산하여 터미널에 출력.
        avg_tps = data['actual_tps'].mean()
        print(f"파일 '{file}' 분석 결과: 평균 실제 TPS = {avg_tps:.2f}")

    except Exception as e:
        print(f"파일 '{file}' 처리 중 오류 발생: {e}")

# --- 3. 그래프 스타일링 ---
plt.title('TPS changes over time (comparison by load level)', fontsize=16)
plt.xlabel('Time', fontsize=12)
plt.ylabel('Transactions processed per second', fontsize=12)
plt.legend(fontsize=12) 
plt.grid(True, which='both', linestyle='--', linewidth=0.5) 
plt.tight_layout() 
# y축 범위 고정
plt.ylim(30, 60)

# --- 4. 그래프 저장 ---
plt.savefig('tps_timeseries_comparison.png')

print("\n그래프가 tps_timeseries_comparison.png 파일로 저장되었습니다.")