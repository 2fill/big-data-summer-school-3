# streamlit run app.py
import json
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
import plotly.express as px
import plotly.graph_objects as go
import streamlit as st
import base64

@st.cache_data
def logo_b64():
    return base64.b64encode(
        (Path(__file__).parent / 'logo_animated.png').read_bytes()).decode()

ARTIFACTS = Path(__file__).parent / 'artifacts'

st.set_page_config(page_title='전기차 충전 인프라 결핍 분석',
                   page_icon='🔌', layout='wide')

# 색상 팔레트
LIME, LIME_DARK, LIME_LIGHT = '#7CB342', '#33691E', '#AED581'
RED, ORANGE, GRAY = '#C62828', '#FB8C00', '#90A4AE'
GREEN_SCALE = ['#C62828', '#EF9A9A', '#F5F5F5', '#C5E1A5', '#33691E']

PLOT_LAYOUT = dict(
    font=dict(family='Pretendard, -apple-system, sans-serif', size=13),
    plot_bgcolor='rgba(0,0,0,0)', paper_bgcolor='rgba(0,0,0,0)',
    margin=dict(l=10, r=10, t=40, b=10),
    hoverlabel=dict(bgcolor='white', font_size=13),
)

# 스타일
st.markdown("""
<style>
  @import url('https://cdn.jsdelivr.net/gh/orioncactus/pretendard@v1.3.9/dist/web/static/pretendard.css');

  html { scroll-behavior:smooth; scroll-padding-top:20px; }
  html, body, [class*="css"] { font-family:'Pretendard', -apple-system, sans-serif; }
  .block-container { padding-top:2rem; max-width:1320px; }

  .hero {
      background:linear-gradient(135deg,#33691E 0%,#7CB342 55%,#AED581 100%);
      border-radius:20px; padding:34px 40px; margin-bottom:26px;
      color:#fff; box-shadow:0 10px 30px rgba(51,105,30,.22);
  }
  .hero h1 { color:#fff !important; margin:0 0 8px 0;
             font-size:2.1rem; font-weight:800; letter-spacing:-.5px; }
  .hero p  { margin:0; opacity:.92; font-size:.95rem; line-height:1.6; }

  h2, h3 { color:#1B5E20; font-weight:700; letter-spacing:-.3px; }

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

  .stTabs [data-baseweb="tab-list"] { gap:4px; border-bottom:2px solid #EDF2E7; }
  .stTabs [data-baseweb="tab"] {
      padding:10px 20px; border-radius:10px 10px 0 0;
      font-weight:600; color:#7A8B6C;
  }
  .stTabs [aria-selected="true"] { color:#33691E !important; background:#F1F8E9; }
  .stTabs [data-baseweb="tab-highlight"] { background-color:#7CB342; height:3px; }

  .panel { border-radius:15px; padding:20px; min-height:200px; display:flex; flex-direction:column; justify-content:center; }
  .panel .tag { font-size:1rem; font-weight:700; letter-spacing:1px;
                text-transform:uppercase; opacity:1; margin-bottom:10px; }
  .panel .big { font-size:2rem; font-weight:800; line-height:1.1; margin:0; }
  .panel .sub { font-size:1rem; margin-top:8px; opacity:.85; }

  .panel-pred {
      background:linear-gradient(135deg,#7CB342,#558B2F); color:#fff;
      box-shadow:0 8px 22px rgba(85,139,47,.25);
  }
  .panel-pred .tag { color:#EAF4DC; }

  .panel-actual { background:#fff; border:2px dashed #B0BEC5; color:#37474F; }
  .panel-actual .tag { color:#78909C; }
  .panel-actual .big { color:#455A64; }

  .chip { display:inline-block; padding:7px 16px; border-radius:20px;
          font-size:.85rem; font-weight:700; }
  .chip-deficit { background:#FFEBEE; color:#C62828; border:1px solid #FFCDD2; }
  .chip-normal  { background:#F1F8E9; color:#33691E; border:1px solid #DCEDC8; }

  .verdict { margin-top:18px; padding:14px 20px; border-radius:12px;
             font-weight:600; font-size:.92rem; }
  .verdict-match { background:#F1F8E9; border-left:4px solid #7CB342; color:#33691E; }
  .verdict-miss  { background:#FFF3E0; border-left:4px solid #FB8C00; color:#E65100; }

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
LOG_FEATURES = {'log_reg': '대', 'log_pop': '명'}

# ══════════════════════════════════════════════════════════
st.markdown(f"""
<style>
  .hero-row {{ display:flex; align-items:center; gap:24px; margin-bottom:16px; }}
  .logo-img {{
      width:200px; height:200px; flex-shrink:0; object-fit:contain;
      filter: drop-shadow(0 4px 12px rgba(0,0,0,.15));
  }}
  .hero-row h1 {{ margin:0 !important; font-size:7rem !important; }}
  .cta {{
      display:inline-flex; align-items:center; gap:8px; margin-top:22px;
      background:#fff; color:#33691E !important; text-decoration:none;
      padding:13px 30px; border-radius:30px;
      font-weight:800; font-size:1rem;
      box-shadow:0 4px 16px rgba(0,0,0,.16); transition:.2s;
  }}
  .cta:hover {{
      transform:translateY(-2px);
      box-shadow:0 8px 22px rgba(0,0,0,.24);
  }}
  .cta .arrow {{ transition:transform .2s; }}
  .cta:hover .arrow {{ transform:translateX(4px); }}
</style>

<div class="hero">
  <div class="hero-row">
    <img class="logo-img" src="data:image/png;base64,{logo_b64()}" alt="EVen">
    <h1>EVen</h1>
  </div>
  <p>시군구별 전기차 등록대수 대비 충전 인프라 과부족을 개수·가동률·혼잡도 세 축에서 분석하고,<br>주택·인구·보조금 지표로 결핍 지역을 예측합니다.</p>
  <a class="cta" href="#simulator">이븐이 사용해보기 <span class="arrow">→</span></a>
</div>
""", unsafe_allow_html=True)

c1, c2, c3, c4 = st.columns(4)
c1.metric('분석 시군구', f"{meta['n_panel']}개")
c2.metric('충전기 평균 가동률', f"{meta['mean_ok_rate']:.1f}%")
c3.metric('3중고 지역', f"{meta['n_triple']}곳")
c4.metric('모델 성능(AUROC)', f"{meta['auroc']:.3f}")

st.divider()

# ══════════════════════════════════════════════════════════
st.header('분석 결과')
tab1, tab2, tab3, tab4 = st.tabs(['개수 갭', '가동률·혼잡도', '3중고 지역', '모델 성능'])

# =================================
# ========== 탭 1: 개수 갭 ==========
with tab1:
    st.caption('지역별 충전기 기대치 대비 괴리율(log-log 회귀 사용)')
    st.subheader('회귀선 대비 실제 충전기 수')
    fit = region.sort_values('registration')
    scat = go.Figure()
    scat.add_trace(go.Scatter(
        x=fit['registration'], y=fit['expected_total'],
        mode='lines', name='기대치 (회귀선)',
        line=dict(color=LIME_DARK, width=2.5, dash='dash'),
        hovertemplate='등록 %{x:,.0f}대 → 기대 %{y:.0f}대<extra></extra>'))
    scat.add_trace(go.Scatter(
        x=region['registration'], y=region['total_chargers'],
        mode='markers', name='실제',
        marker=dict(size=8, color=region['gap_pct_total'],
                    colorscale=GREEN_SCALE, cmid=0, opacity=.85,
                    line=dict(width=.5, color='white'),
                    colorbar=dict(title='괴리율<br>(%)', thickness=14)),
        text=region['지역'],
        hovertemplate='<b>%{text}</b><br>등록 %{x:,.0f}대<br>'
                      '충전기 %{y:,.0f}대<extra></extra>'))
    scat.update_layout(**PLOT_LAYOUT, height=460, xaxis_type='log', yaxis_type='log',
                       xaxis_title='전기차 등록대수 (로그)',
                       yaxis_title='충전기 수 (로그)',
                       legend=dict(orientation='h', y=1.08, x=0))
    scat.update_xaxes(gridcolor='#EDF2E7')
    scat.update_yaxes(gridcolor='#EDF2E7')
    st.plotly_chart(scat, use_container_width=True)

    col_a, col_b = st.columns([3, 2])
    with col_a:
        st.subheader('괴리율 하위 지역')
        n_show = st.slider('표시 개수', 10, 40, 20, key='gap_n')
        worst = region.nsmallest(n_show, 'gap_pct_total').sort_values('gap_pct_total')
        bar = px.bar(worst, x='gap_pct_total', y='지역', orientation='h',
                     color='gap_pct_total', color_continuous_scale=GREEN_SCALE,
                     range_color=[-100, 100],
                     labels={'gap_pct_total': '괴리율 (%)', '지역': ''},
                     hover_data={'registration': ':,', 'total_chargers': ':,'})
        bar.update_layout(**PLOT_LAYOUT, height=max(340, n_show * 22),
                          coloraxis_showscale=False)
        bar.update_xaxes(gridcolor='#EDF2E7', zerolinecolor='#B0BEC5')
        st.plotly_chart(bar, use_container_width=True)

    with col_b:
        st.subheader('시도별 중앙값')
        by_sido = (region.groupby('sido_short')['gap_pct_total']
                   .median().sort_values().reset_index())
        sido_bar = px.bar(by_sido, x='gap_pct_total', y='sido_short', orientation='h',
                          color='gap_pct_total', color_continuous_scale=GREEN_SCALE,
                          range_color=[-60, 60],
                          labels={'gap_pct_total': '괴리율 중앙값 (%)', 'sido_short': ''})
        sido_bar.update_layout(**PLOT_LAYOUT, height=440, coloraxis_showscale=False)
        sido_bar.update_xaxes(gridcolor='#EDF2E7', zerolinecolor='#B0BEC5')
        st.plotly_chart(sido_bar, use_container_width=True)

# =====================================
# ========== 탭 2: 가동률/혼잡도 ==========
with tab2:
    st.caption('전기차 충전기의 실제 작동 여부와 혼잡도(표본 10 미만 시군구 제거)')
    ops = region.dropna(subset=['ok_rate', 'busy_rate'])

    col_a, col_b = st.columns(2)
    with col_a:
        st.subheader('가동률 하위 10')
        low_ok = ops.nsmallest(10, 'ok_rate').sort_values('ok_rate')
        f = px.bar(low_ok, x='ok_rate', y='지역', orientation='h',
                   color='ok_rate', color_continuous_scale=['#C62828', '#FFB74D', LIME],
                   labels={'ok_rate': '가동률 (%)', '지역': ''},
                   hover_data={'broken_rate': ':.1f', 'n_reported': ':,'})
        f.add_vline(x=ops['ok_rate'].median(), line_dash='dash', line_color=GRAY,
                    annotation_text='중앙값')
        f.update_layout(**PLOT_LAYOUT, height=380, coloraxis_showscale=False)
        f.update_xaxes(gridcolor='#EDF2E7')
        st.plotly_chart(f, use_container_width=True)

    with col_b:
        st.subheader('혼잡도 상위 10')
        high_busy = ops.nlargest(10, 'busy_rate').sort_values('busy_rate')
        f = px.bar(high_busy, x='busy_rate', y='지역', orientation='h',
                   color='busy_rate', color_continuous_scale=['#DCEDC8', LIME_DARK],
                   labels={'busy_rate': '혼잡도 (%)', '지역': ''},
                   hover_data={'ok_rate': ':.1f'})
        f.add_vline(x=ops['busy_rate'].median(), line_dash='dash', line_color=GRAY,
                    annotation_text='중앙값')
        f.update_layout(**PLOT_LAYOUT, height=380, coloraxis_showscale=False)
        f.update_xaxes(gridcolor='#EDF2E7')
        st.plotly_chart(f, use_container_width=True)

    st.subheader('시도별 가동률 분포')
    st.caption('상자가 길수록 시군구별 편차가 큽니다.')
    order = ops.groupby('sido_short')['ok_rate'].median().sort_values().index
    box = px.box(ops, x='sido_short', y='ok_rate', points='all',
                 category_orders={'sido_short': list(order)},
                 color_discrete_sequence=[LIME],
                 labels={'sido_short': '', 'ok_rate': '가동률 (%)'},
                 hover_data=['지역'])
    box.update_traces(marker=dict(size=5, opacity=.6))
    box.update_layout(**PLOT_LAYOUT, height=400)
    box.update_yaxes(gridcolor='#EDF2E7')
    st.plotly_chart(box, use_container_width=True)

    st.subheader('충전기 개수와 혼잡도 관계')
    st.caption(f'원 크기는 등록대수, 색은 가동률입니다.')
    r_val = ops['gap_pct_total'].corr(ops['busy_rate'])
    sc = px.scatter(ops, x='gap_pct_total', y='busy_rate',
                    size='registration', size_max=32,
                    color='ok_rate', color_continuous_scale=['#C62828', '#FFB74D', LIME],
                    hover_name='지역',
                    labels={'gap_pct_total': '괴리율 (%)', 'busy_rate': '혼잡도 (%)',
                            'ok_rate': '가동률(%)', 'registration': '등록대수'})
    sc.add_vline(x=0, line_dash='dash', line_color='#CFD8DC')
    sc.update_layout(**PLOT_LAYOUT, height=440)
    sc.update_xaxes(gridcolor='#EDF2E7')
    sc.update_yaxes(gridcolor='#EDF2E7')
    st.plotly_chart(sc, use_container_width=True)

# ================================
# ========== 탭 3: 3중고 ==========
with tab3:
    st.caption('개수 부족 하위 20% + 가동률 중앙값 이하 + 혼잡도 중앙값 이상 만족 지역')

    ops = region.dropna(subset=['ok_rate', 'busy_rate'])
    gap_cut = region['gap_pct_total'].quantile(0.20)
    ok_med = ops['ok_rate'].median()
    busy_med = ops['busy_rate'].median()

    is_triple = ((ops['gap_pct_total'] <= gap_cut) &
                 (ops['ok_rate'] <= ok_med) &
                 (ops['busy_rate'] >= busy_med))
    plot_df = ops.assign(구분=np.where(is_triple, '3중고', '해당 없음'))
    triple = ops[is_triple]

    st.subheader('괴리율-혼잡도 사분면으로 본 위험 구역')
    st.caption('왼쪽 위로 갈수록 부족하면서 붐빕니다.')
    q = px.scatter(plot_df, x='gap_pct_total', y='busy_rate',
                   color='구분', size='registration', size_max=34,
                   color_discrete_map={'3중고': RED, '해당 없음': '#CFD8DC'},
                   hover_name='지역',
                   hover_data={'ok_rate': ':.1f', 'registration': ':,',
                               'gap_pct_total': ':.1f', 'busy_rate': ':.1f'},
                   labels={'gap_pct_total': '괴리율 (%)', 'busy_rate': '혼잡도 (%)'})
    q.add_vline(x=gap_cut, line_dash='dash', line_color=RED,
                annotation_text='개수 부족 컷', annotation_position='top')
    q.add_hline(y=busy_med, line_dash='dash', line_color=ORANGE,
                annotation_text='혼잡도 중앙값', annotation_position='right')
    q.add_vrect(x0=plot_df['gap_pct_total'].min() - 5, x1=gap_cut,
                y0=0, y1=1, yref='paper', fillcolor=RED, opacity=.05, line_width=0)
    q.update_layout(**PLOT_LAYOUT, height=480,
                    legend=dict(orientation='h', y=1.08, x=0))
    q.update_xaxes(gridcolor='#EDF2E7')
    q.update_yaxes(gridcolor='#EDF2E7')
    st.plotly_chart(q, use_container_width=True)

    if len(triple) > 0:
        st.subheader('3중고 지역 지표 비교')
        st.caption('세 축 모두 바깥쪽일수록 양호합니다.')
        radar = go.Figure()
        for _, r in triple.iterrows():
            radar.add_trace(go.Scatterpolar(
                r=[max(0, 100 + r['gap_pct_total']),  # 부족할수록 작게
                   r['ok_rate'],
                   100 - r['busy_rate']],             # 붐빌수록 작게
                theta=['충전기 충족도', '가동률', '여유도'],
                fill='toself', name=r['지역'], opacity=.45))
        radar.update_layout(**PLOT_LAYOUT, height=440,
                            polar=dict(radialaxis=dict(visible=True, range=[0, 100],
                                                       gridcolor='#EDF2E7')))
        st.plotly_chart(radar, use_container_width=True)
    else:
        st.info('현재 기준으로 3중고에 해당하는 지역이 없습니다.')

# ==================================
# ========== 탭 4: 모델 성능 ==========
with tab4:
    st.caption('최종 모델: Weighted Soft Voting(LogisticRegression+XGBoost+LightGBM)')

    p = perf.reset_index()
    p.columns = ['모델'] + list(p.columns[1:])
    p['구분'] = np.where(p['모델'].str.contains(r'\('), '앙상블', '단일모델')

    st.subheader('AUROC 순위')
    st.caption('진한 색이 앙상블, 연한 색이 단일 모델입니다.')
    rank = p.sort_values('AUROC')
    f = px.bar(rank, x='AUROC', y='모델', orientation='h', color='구분',
               color_discrete_map={'단일모델': LIME_LIGHT, '앙상블': LIME_DARK},
               range_x=[max(0.5, rank['AUROC'].min() - .05), 1.0],
               hover_data={'BalancedAccuracy': ':.3f', 'Sensitivity': ':.3f'})
    f.update_layout(**PLOT_LAYOUT, height=640, showlegend=False)
    f.update_xaxes(gridcolor='#EDF2E7')
    st.plotly_chart(f, use_container_width=True)

    st.subheader('상위 5개 지표 비교')
    top5 = p.nlargest(5, 'AUROC')
    metrics = ['AUROC', 'BalancedAccuracy', 'Sensitivity', 'Specificity', 'F1']
    melted = top5.melt(id_vars='모델', value_vars=metrics,
                        var_name='지표', value_name='값')
    f = px.bar(melted, x='지표', y='값', color='모델', barmode='group',
                color_discrete_sequence=[LIME_DARK, LIME, LIME_LIGHT,
                                        '#8D6E63', '#B0BEC5'])
    f.update_layout(**PLOT_LAYOUT, height=420, yaxis_range=[0, 1],
                    legend=dict(orientation='h', y=-.25, x=0, font_size=11))
    f.update_yaxes(gridcolor='#EDF2E7')
    st.plotly_chart(f, use_container_width=True)

st.divider()

# ══════════════════════════════════════════════════════════
st.markdown('<div id="simulator"></div>', unsafe_allow_html=True)
st.header('이븐이 시뮬레이터')
st.markdown('사이드바에서 값을 조절하면 모델이 해당 조건의 지역을 '
            '**결핍으로 분류할 확률**을 실시간으로 계산합니다.')

# 시도 → 시군구 2단계 선택
avail = region.dropna(subset=FEATURES)
SIDO_ORDER = ['서울', '경기', '인천', '강원', '충북', '충남', '대전', '세종',
              '전북', '전남', '광주', '경북', '대구', '경남', '부산', '울산', '제주']
sido_list = [s for s in SIDO_ORDER if s in set(avail['sido_short'])]

st.markdown('**1. 시도 선택**')
sido = st.radio('시도', sido_list, horizontal=True, label_visibility='collapsed')

sgg_list = sorted(avail[avail['sido_short'] == sido]['sigungu'].tolist())
st.markdown("<div style='margin-top:20px;'><b>2. 시군구 선택</b></div>",
            unsafe_allow_html=True)

sgg = st.radio('시군구', sgg_list, horizontal=True, label_visibility='collapsed')

preset = f'{sido} {sgg}'
row = avail[avail['지역'] == preset].iloc[0]
defaults = {f: float(row[f]) for f in FEATURES}

# 지역이 바뀌면 슬라이더를 그 지역 값으로 초기화
if st.session_state.get('_preset') != preset:
    st.session_state['_preset'] = preset
    for f in FEATURES:
        st.session_state.pop(f, None)

st.sidebar.header('입력값 조절')
st.sidebar.caption('슬라이더 범위는 학습 데이터의 실제 최소~최대입니다.')

if st.sidebar.button(f'{preset} 값으로 되돌리기', use_container_width=True):
    for f in FEATURES:
        st.session_state.pop(f, None)
    st.rerun()

values = {}
for f in FEATURES:
    s = stats[f]
    if f in LOG_FEATURES:
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

X_input = np.array([[values[f] for f in FEATURES]])
proba = float(bundle['model'].predict_proba(X_input)[0, 1])
thresh = bundle['threshold']
pred_deficit = proba >= thresh
pred_txt = '결핍' if pred_deficit else '결핍 아님'

actual = row.get('is_deficit') if row is not None else None
has_actual = actual is not None and pd.notna(actual)

st.markdown("<div style='margin-top:20px;'></div>", unsafe_allow_html=True)
col_pred, col_actual = st.columns(2)

with col_pred:
    st.markdown(f"""
    <div class="panel panel-pred">
      <div class="tag">이븐이의 예측</div>
      <p class="big">{proba:.0%}</p>
      <div class="sub">{thresh:.0%} 넘으면 부족</div>
      <div class="sub" style="margin-top:14px;">
        <span style="background:rgba(255,255,255,.22); padding:6px 14px;
              border-radius:20px; font-weight:700;">{pred_txt}</span>
      </div>
    </div>
    """, unsafe_allow_html=True)

with col_actual:
    if has_actual:
        actual_txt = '부족한 동네' if actual == 1 else '부족하지 않음'
        chip = 'chip-deficit' if actual == 1 else 'chip-normal'
        st.markdown(f"""
        <div class="panel panel-actual">
          <div class="tag">실제 데이터</div>
          <p class="big">{actual_txt}</p>
          <div class="sub">전국 하위 20%면 부족</div>
          <div class="sub" style="margin-top:14px;">
            <span class="chip {chip}">정답</span>
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

if has_actual:
    match = (actual == 1) == pred_deficit
    cls = 'verdict-match' if match else 'verdict-miss'
    msg = ('이븐이가 맞혔습니다!' if match
           else '이븐이가 실수했어요 ㅠㅠ')