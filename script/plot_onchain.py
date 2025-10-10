# plot_onchain.py
import pandas as pd
import matplotlib.pyplot as plt

# CSV 파일 읽기
try:
    data = pd.read_csv('onchain_performance.csv')
except FileNotFoundError:
    print("Error: onchain_performance.csv not found. Please run analyze_logs.sh first.")
    exit()

# 그래프 생성
plt.figure(figsize=(10, 6))
plt.plot(data.index, data['duration_seconds'], marker='o', linestyle='-')

# 그래프 제목 및 라벨 설정
plt.title('On-Chain Logic Execution Time (AggregateScoresAndCreateATT)')
plt.xlabel('Execution Count (Round)')
plt.ylabel('Duration (seconds)')
plt.grid(True)
plt.tight_layout()

# 그래프를 이미지 파일로 저장
plt.savefig('onchain_performance.png')

print("Graph saved to onchain_performance.png")
# plt.show() # 로컬 환경에서 바로 그래프를 보고 싶을 때 주석 해제