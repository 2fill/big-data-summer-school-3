# streamlit run app.py
import json
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
import streamlit as st

ARTIFACTS = Path(__file__).parent / 'artifacts'

st.set_page_config(page_title='전기차 충전 인프라 결핍 분석',
                   page_icon='🔌', layout='wide')

# 스타일
st.markdown("""
<style>
  @import url('https://cdn.jsdelivr.net/gh/orioncactus/pretendard@v1.3.9/dist/web/static/pretendard.css');

  html, body, [class*="css"] { font-family:'Pretendard', -apple-system, sans-serif; }
  .block-container { padding-top:2rem; max-width:1280px; }

  /* 히어로 */
  .hero {
      background:linear-gradient(135deg,#33691E 0%,#7CB342 55%,#AED581 100%);
      border-radius:20px; padding:34px 40px; margin-bottom:26px;
      color:#fff; box-shadow:0 10px 30px rgba(51,105,30,.22);
  }
  .hero h1 { color:#fff !important; margin:0 0 8px 0;
             font-size:2.1rem; font-weight:800; letter-spacing:-.5px; }
  .hero p  { margin:0; opacity:.92; font-size:.95rem; line-height:1.6; }

  h2, h3 { color:#1B5E20; font-weight:700; letter-spacing:-.3px; }

  /* KPI 카드 */
  div[data-testid="stMetric"] {
      background:#fff; border:1px solid #E0E8D8; border-top:3px solid #7CB342;
      padding:18px 20px; border-radius:14px;
      box-shadow:0 2px 10px rgba(0,0,0,.04); transition:.2s;
  }
  div[data-testid="stMetric"]:hover {
      box-shadow:0 6px 18px rgba(124,179,66,.18); transform:translateY(-2px);
  }
  div[data-testid="stMetricValue"] { color:#33691E; font-weight:800; }
  div[data-testid="stMetricLabel"] { color:#7A8B6C; font-size:.82rem; font-weight:600; }

  /* 탭 */
  .stTabs [data-baseweb="tab-list"] { gap:4px; border-bottom:2px solid #EDF2E7; }
  .stTabs [data-baseweb="tab"] {
      padding:10px 20px; border-radius:10px 10px 0 0;
      font-weight:600; color:#7A8B6C;
  }
  .stTabs [aria-selected="true"] { color:#33691E !important; background:#F1F8E9; }
  .stTabs [data-baseweb="tab-highlight"] { background-color:#7CB342; height:3px; }

  /* 결과 패널 */
  .panel { border-radius:16px; padding:22px 26px; height:100%; }
  .panel .tag { font-size:.75rem; font-weight:700; letter-spacing:1px;
                text-transform:uppercase; opacity:.8; margin-bottom:10px; }
  .panel .big { font-size:2.5rem; font-weight:800; line-height:1.1; margin:0; }
  .panel .sub { font-size:.85rem; margin-top:8px; opacity:.85; }

  /* 모델 예측 = 연두 채움 */
  .panel-pred {
      background:linear-gradient(135deg,#7CB342,#558B2F); color:#fff;
      box-shadow:0 8px 22px rgba(85,139,47,.25);
  }
  .panel-pred .tag { color:#EAF4DC; }

  /* 실제 라벨 = 회색 테두리 */
  .panel-actual { background:#fff; border:2px dashed #B0BEC5; color:#37474F; }
  .panel-actual .tag { color:#78909C; }
  .panel-actual .big { color:#455A64; }

  /* 배지 */
  .chip { display:inline-block; padding:7px 16px; border-radius:20px;
          font-size:.85rem; font-weight:700; }
  .chip-deficit { background:#FFEBEE; color:#C62828; border:1px solid #FFCDD2; }
  .chip-normal  { background:#F1F8E9; color:#33691E; border:1px solid #DCEDC8; }

  /* 일치 여부 */
  .verdict { margin-top:18px; padding:14px 20px; border-radius:12px;
             font-weight:600; font-size:.92rem; }
  .verdict-match { background:#F1F8E9; border-left:4px solid #7CB342; color:#33691E; }
  .verdict-miss  { background:#FFF3E0; border-left:4px solid #FB8C00; color:#E65100; }

  .stProgress > div > div > div > div {
      background:linear-gradient(90deg,#AED581,#558B2F);
  }
  section[data-testid="stSidebar"] { background:#FAFCF8; border-right:1px solid #E8EFE0; }
  section[data-testid="stSidebar"] h2 { font-size:1.1rem; }
  hr { border-color:#EDF2E7; }
</style>
""", unsafe_allow_html=True)


@st.cache_resource
def load_model():
    return joblib.load(ARTIFACTS / 'deficit_model.pkl')


@st.cache_data
def load_data():
    region = pd.read_csv(ARTIFACTS / 'region_metrics.csv')
    perf = pd.read_csv(ARTIFACTS / 'model_performance.csv', index_col=0)
    with open(ARTIFACTS / 'feature_stats.json', encoding='utf-8') as fp:
        meta = json.load(fp)
    region['지역'] = region['sido_short'] + ' ' + region['sigungu']
    return region, perf, meta


bundle = load_model()
region, perf, meta = load_data()
FEATURES = bundle['features']
stats = meta['stats']

LABELS = {
    'log_reg': '전기차 등록대수',
    'log_pop': '인구수',
    'apt_ratio': '아파트 비율',
    'old_housing_ratio': '노후주택 비율',
    'parking_ratio': '자가주차장 확보율',
    'subsidy_receipt_rate': '보조금 접수율 (%)',
    'budget_exec_rate': '예산 소진율 (%)',
}
LOG_FEATURES = {'log_reg': '대', 'log_pop': '명'}  # 원 스케일로 입력받을 변수

# ══════════════════════════════════════════════════════════
st.markdown("""
<div class="hero">
  <h1>전기차 충전 인프라 결핍 분석</h1>
  <p>시군구별 전기차 등록대수 대비 충전 인프라 과부족을 개수·가동률·혼잡도·용량 네 축에서 분석하고,<br>
     주택·인구·보조금 지표로 결핍 지역을 예측합니다.</p>
</div>
""", unsafe_allow_html=True)

c1, c2, c3, c4 = st.columns(4)
c1.metric('분석 시군구', f"{meta['n_panel']}개")
c2.metric('평균 가동률', f"{meta['mean_ok_rate']:.1f}%")
c3.metric('3중고 지역', f"{meta['n_triple']}곳")
c4.metric('모델 AUROC', f"{meta['auroc']:.3f}")

st.divider()

# ══════════════════════════════════════════════════════════
st.header('분석 결과')
tab1, tab2, tab3, tab4 = st.tabs(['개수 갭', '가동률·혼잡도', '3중고 지역', '모델 성능'])

with tab1:
    st.markdown('충전기 절대 개수는 대도시가 유리하므로, **log-log 회귀로 규모효과를 제거한 '
                '기대치 대비 괴리율**을 사용합니다. 음수면 기대보다 부족합니다.')
    n_show = st.slider('표시 개수', 10, 50, 20, key='gap_n')
    worst = region.nsmallest(n_show, 'gap_pct_total')
    st.bar_chart(worst.set_index('지역')['gap_pct_total'], color='#7CB342')
    st.dataframe(
        worst[['지역', 'registration', 'total_chargers',
               'expected_total', 'gap_pct_total']]
        .rename(columns={'registration': '등록대수', 'total_chargers': '충전기',
                         'expected_total': '기대치', 'gap_pct_total': '괴리율(%)'})
        .round(1), use_container_width=True, hide_index=True)

with tab2:
    st.markdown('설치 여부와 별개로 **실제로 작동하는가**, 그리고 **얼마나 붐비는가**를 봅니다. '
                '표본 10대 미만 시군구는 비율이 불안정해 제외했습니다.')
    col_a, col_b = st.columns(2)
    with col_a:
        st.subheader('가동률 하위 10')
        low_ok = region.dropna(subset=['ok_rate']).nsmallest(10, 'ok_rate')
        st.bar_chart(low_ok.set_index('지역')['ok_rate'], color='#7CB342')
    with col_b:
        st.subheader('혼잡도 상위 10')
        high_busy = region.dropna(subset=['busy_rate']).nlargest(10, 'busy_rate')
        st.bar_chart(high_busy.set_index('지역')['busy_rate'], color='#558B2F')

    st.subheader('개수 부족과 혼잡도의 관계')
    st.scatter_chart(region.dropna(subset=['busy_rate']),
                     x='gap_pct_total', y='busy_rate', color='#7CB342')
    st.caption('두 축이 독립적이라면 뚜렷한 패턴이 보이지 않습니다.')

with tab3:
    st.markdown('**개수 부족 하위 20% + 가동률 중앙값 이하 + 혼잡도 중앙값 이상**을 '
                '동시에 만족하는 지역입니다. 정책 우선순위가 가장 높은 후보입니다.')
    gap_cut = region['gap_pct_total'].quantile(0.20)
    ok_med = region['ok_rate'].median()
    busy_med = region['busy_rate'].median()
    triple = region[(region['gap_pct_total'] <= gap_cut) &
                    (region['ok_rate'] <= ok_med) &
                    (region['busy_rate'] >= busy_med)]
    st.dataframe(
        triple[['지역', 'registration', 'gap_pct_total', 'ok_rate', 'busy_rate']]
        .rename(columns={'registration': '등록대수', 'gap_pct_total': '괴리율(%)',
                         'ok_rate': '가동률(%)', 'busy_rate': '혼잡도(%)'})
        .round(1).sort_values('괴리율(%)'),
        use_container_width=True, hide_index=True)

with tab4:
    st.markdown(f"5-fold 교차검증 · Youden's J로 임계값 결정. "
                f"최종 선정: **{meta['best_model']}**")
    st.dataframe(perf.round(3), use_container_width=True)

st.divider()

# ══════════════════════════════════════════════════════════
st.header('결핍 예측 시뮬레이터')
st.markdown('사이드바에서 값을 조절하면 모델이 해당 조건의 지역을 '
            '**결핍으로 분류할 확률**을 실시간으로 계산합니다.')

preset_options = ['(직접 입력)'] + sorted(
    region.dropna(subset=FEATURES)['지역'].tolist())
preset = st.selectbox('시군구 불러오기', preset_options,
                      help='실제 지역의 값을 불러온 뒤 조절해볼 수 있습니다.')

if preset != '(직접 입력)':
    row = region[region['지역'] == preset].iloc[0]
    defaults = {f: float(row[f]) for f in FEATURES}
else:
    row = None
    defaults = {f: stats[f]['median'] for f in FEATURES}

# ── 입력 ─────────────────────────────────────────────────────
st.sidebar.header('입력값 조절')
st.sidebar.caption('슬라이더 범위는 학습 데이터의 실제 최소~최대입니다.')

values = {}
for f in FEATURES:
    s = stats[f]
    if f in LOG_FEATURES:  # 로그 변수는 원 스케일로 입력받고 내부에서 log 변환
        lo, hi = int(np.exp(s['min'])), int(np.exp(s['max']))
        raw = st.sidebar.slider(f'{LABELS[f]} ({LOG_FEATURES[f]})',
                                lo, hi, int(np.exp(defaults[f])),
                                step=max(1, (hi - lo) // 200), key=f)
        values[f] = float(np.log(max(raw, 1)))
    else:
        span = s['max'] - s['min']
        values[f] = st.sidebar.slider(
            LABELS[f], float(s['min']), float(s['max']), float(defaults[f]),
            step=float(span / 100) if span else 0.01, key=f)

# ── 예측 ─────────────────────────────────────────────────────
X_input = np.array([[values[f] for f in FEATURES]])
proba = float(bundle['model'].predict_proba(X_input)[0, 1])
thresh = bundle['threshold']
pred_deficit = proba >= thresh
pred_txt = '결핍' if pred_deficit else '결핍 아님'

actual = row.get('is_deficit') if row is not None else None
has_actual = actual is not None and pd.notna(actual)

col_pred, col_actual = st.columns(2)

with col_pred:
    st.markdown(f"""
    <div class="panel panel-pred">
      <div class="tag">MODEL PREDICTION</div>
      <p class="big">{proba:.1%}</p>
      <div class="sub">결핍 확률 · 판정 기준 {thresh:.1%}</div>
      <div class="sub" style="margin-top:14px;">
        <span style="background:rgba(255,255,255,.22); padding:6px 14px;
              border-radius:20px; font-weight:700;">{pred_txt}</span>
      </div>
    </div>
    """, unsafe_allow_html=True)

with col_actual:
    if has_actual:
        actual_txt = '결핍' if actual == 1 else '결핍 아님'
        chip = 'chip-deficit' if actual == 1 else 'chip-normal'
        st.markdown(f"""
        <div class="panel panel-actual">
          <div class="tag">ACTUAL LABEL</div>
          <p class="big">{actual_txt}</p>
          <div class="sub">{preset} · 괴리율 하위 20% 기준</div>
          <div class="sub" style="margin-top:14px;">
            <span class="chip {chip}">실측 데이터</span>
          </div>
        </div>
        """, unsafe_allow_html=True)
    else:
        st.markdown("""
        <div class="panel panel-actual" style="display:flex;
             align-items:center; justify-content:center; min-height:180px;">
          <div style="text-align:center; color:#90A4AE;">
            <div style="font-size:2rem;">—</div>
            <div class="sub">시군구를 선택하면<br>실제 라벨과 비교할 수 있습니다</div>
          </div>
        </div>
        """, unsafe_allow_html=True)

st.progress(min(proba, 1.0))

if has_actual:
    match = (actual == 1) == pred_deficit
    cls = 'verdict-match' if match else 'verdict-miss'
    msg = ('모델 예측이 실제 라벨과 일치합니다.' if match
           else '모델 예측이 실제 라벨과 다릅니다.')
    st.markdown(f"""
    <div class="verdict {cls}">{msg}
      슬라이더를 움직이면 입력값이 실제 지역과 달라지므로 참고용입니다.
    </div>
    """, unsafe_allow_html=True)