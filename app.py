# Streamlit 앱용 산출물 내보내기
import json, shutil

ARTIFACTS = DATA_DIR / 'artifacts'
ARTIFACTS.mkdir(exist_ok=True)

# 1. 모델
shutil.copy(model_path, ARTIFACTS / 'deficit_model.pkl')

# 2. 시군구별 전체 지표 + 모델 변수 + 라벨을 한 파일로
extra = [f for f in FEATURES if f not in sigungu_full.columns]
region_table = sigungu_full.merge(
    model_df[['sido_short', 'sigungu'] + extra + ['is_deficit']],
    on=['sido_short', 'sigungu'], how='left'
)
region_table.to_csv(ARTIFACTS / 'region_metrics.csv', index=False, encoding='utf-8-sig')
log_shape(region_table, '앱용 지역 테이블')

# 3. 모델 성능 순위
combined.to_csv(ARTIFACTS / 'model_performance.csv', encoding='utf-8-sig')

# 4. 슬라이더 범위 + 메타
feature_stats = {
    f: {'min': float(model_df[f].min()),
        'max': float(model_df[f].max()),
        'median': float(model_df[f].median())}
    for f in FEATURES
}
with open(ARTIFACTS / 'feature_stats.json', 'w', encoding='utf-8') as fp:
    json.dump({
        'features': FEATURES,
        'stats': feature_stats,
        'n_model': int(len(model_df)),
        'n_panel': int(len(sigungu_full)),
        'prevalence': float(prevalence),
        'gap_cutoff': float(cutoff),
        'best_model': BEST_NAME,
        'threshold': float(best_thresh),
        'auroc': float(combined.loc[BEST_NAME, 'AUROC']),
        'mean_ok_rate': float(status_stable['ok_rate'].mean()),
        'mean_busy_rate': float(status_stable['busy_rate'].mean()),
        'n_triple': int(len(triple_burden)),
    }, fp, ensure_ascii=False, indent=2)