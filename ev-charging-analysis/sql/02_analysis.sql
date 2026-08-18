/* ============================================================================
   전기차 충전 인프라 분석 — Snowflake SQL 세트
   목적: ① 커버리지·공백  ② 이용률·가동률  ③ 신규 입지 추천
   ----------------------------------------------------------------------------
   [사용 전 1분 세팅]
   아래 0번 블록의 뷰 3개만 실제 테이블/컬럼에 맞게 고치면
   1~9번 쿼리는 그대로 돌아갑니다. (아래 쿼리는 절대 수정 불필요)
   ============================================================================ */

USE WAREHOUSE COMPUTE_WH;              -- ← 본인 웨어하우스
USE DATABASE  EV_ANALYTICS;
USE SCHEMA    ANALYSIS;


/* ============================================================================
   0. 어댑터 레이어 — 여기만 고치세요
   ============================================================================ */

-- 0-1. 충전기 마스터 (충전기 1대 = 1행)
--      원본: 한국환경공단 전기차 충전소 위치/운영정보 계열 스키마 기준
CREATE OR REPLACE VIEW EV_ANALYTICS.ANALYSIS.V_CHARGER AS
SELECT
    STAT_ID                              AS station_id,      -- 충전소 ID
    STAT_NM                              AS station_nm,      -- 충전소명
    CHGER_ID                             AS charger_id,      -- 충전기 ID
    STAT_ID || '-' || CHGER_ID           AS charger_key,     -- 복합키
    ADDR                                 AS addr,
    TRY_TO_DOUBLE(TO_VARCHAR(LAT))                   AS lat,
    TRY_TO_DOUBLE(TO_VARCHAR(LNG))                   AS lng,
    ZCODE                                AS sido_cd,         -- 시도 코드
    ZSCODE                               AS sigungu_cd,      -- 시군구 코드
    BUSI_NM                              AS operator_nm,     -- 운영기관
    TRY_TO_DOUBLE(TO_VARCHAR(OUTPUT))                AS output_kw,       -- 충전기 용량(kW)
    CHGER_TYPE                           AS charger_type_cd,
    KIND                                 AS place_kind_cd,   -- 설치장소 구분
    PARKING_FREE                         AS parking_free_yn,
    LIMIT_YN                             AS limit_yn,        -- 이용자 제한
    STAT                                 AS status_cd,       -- 현재 상태코드
    TRY_TO_TIMESTAMP(TO_VARCHAR(STAT_UPD_DT), 'YYYYMMDDHH24MISS') AS status_upd_ts
FROM EV_ANALYTICS.RAW_EV.CHARGER_STATUS                      -- ← 실제 원본 테이블로 교체
;

-- 0-2. 충전 세션 로그 (충전 1회 = 1행). 없으면 3~5번 쿼리는 건너뛰세요.
CREATE OR REPLACE VIEW EV_ANALYTICS.ANALYSIS.V_SESSION AS
SELECT
    SESSION_ID                           AS session_id,
    STAT_ID                              AS station_id,
    STAT_ID || '-' || CHGER_ID           AS charger_key,
    START_TS                             AS start_ts,
    END_TS                               AS end_ts,
    TRY_TO_DOUBLE(TO_VARCHAR(KWH))                   AS kwh,
    TRY_TO_DOUBLE(TO_VARCHAR(AMOUNT))                AS amount_krw
FROM EV_ANALYTICS.RAW_EV.CHARGE_SESSION                      -- ← 실제 원본 테이블로 교체
WHERE END_TS > START_TS
;

-- 0-3. 지역 수요 기준 (시군구 단위). 인구·EV등록대수는 필수 입력.
CREATE OR REPLACE VIEW EV_ANALYTICS.ANALYSIS.V_REGION AS
SELECT
    SIGUNGU_CD                           AS sigungu_cd,
    SIDO_NM                              AS sido_nm,
    SIGUNGU_NM                           AS sigungu_nm,
    POPULATION                           AS population,
    EV_REGISTERED                        AS ev_cnt,          -- 전기차 등록대수
    AREA_KM2                             AS area_km2
FROM EV_ANALYTICS.REF_GEO.REGION_STATS                       -- ← 실제 원본 테이블로 교체
;

-- 0-4. 코드값 매핑 (환경공단 코드 기준 — 다르면 여기서 조정)
CREATE OR REPLACE VIEW EV_ANALYTICS.ANALYSIS.V_CHARGER_ENRICHED AS
SELECT
    c.*,
    CASE WHEN c.output_kw >= 100 THEN '초급속'
         WHEN c.output_kw >= 50  THEN '급속'
         WHEN c.output_kw >= 20  THEN '중속'
         ELSE '완속' END                                     AS speed_tier,
    CASE c.status_cd
         WHEN '1' THEN '통신이상' WHEN '2' THEN '충전대기'
         WHEN '3' THEN '충전중'   WHEN '4' THEN '운영중지'
         WHEN '5' THEN '점검중'   WHEN '9' THEN '상태미확인'
         ELSE '기타' END                                     AS status_nm,
    (c.status_cd IN ('2','3'))                               AS is_healthy,
    H3_LATLNG_TO_CELL_STRING(c.lat, c.lng, 7)                AS h3_r7,  -- ≈5km 셀
    H3_LATLNG_TO_CELL_STRING(c.lat, c.lng, 8)                AS h3_r8,  -- ≈1.8km 셀
    ST_MAKEPOINT(c.lng, c.lat)                               AS geom
FROM EV_ANALYTICS.ANALYSIS.V_CHARGER c
WHERE c.lat BETWEEN 33 AND 39 AND c.lng BETWEEN 124 AND 132   -- 한반도 범위 밖 좌표 제거
;


/* ============================================================================
   1. 전체 현황 KPI  →  대시보드 상단 지표 카드
   ============================================================================ */
SELECT
    COUNT(*)                                                       AS "총_충전기수",
    COUNT(DISTINCT station_id)                                     AS "총_충전소수",
    COUNT_IF(speed_tier IN ('급속','초급속'))                       AS "급속_충전기수",
    ROUND(100.0 * COUNT_IF(speed_tier IN ('급속','초급속')) / NULLIF(COUNT(*),0), 1)
                                                                   AS "급속_비중_pct",
    ROUND(100.0 * COUNT_IF(is_healthy) / NULLIF(COUNT(*),0), 1)    AS "정상가동률_pct",
    COUNT_IF(status_cd IN ('1','4','5'))                           AS "이상_충전기수",
    COUNT(DISTINCT operator_nm)                                    AS "운영사수",
    ROUND(SUM(output_kw)/1000, 1)                                  AS "총_설비용량_MW"
FROM EV_ANALYTICS.ANALYSIS.V_CHARGER_ENRICHED;


/* ============================================================================
   2. 커버리지 — 시군구별 보급 수준 + 공급부족 지수
   ============================================================================ */
WITH by_region AS (
    SELECT
        sigungu_cd,
        COUNT(*)                                        AS charger_cnt,
        COUNT_IF(speed_tier IN ('급속','초급속'))        AS fast_cnt,
        COUNT(DISTINCT station_id)                      AS station_cnt,
        SUM(output_kw)                                  AS total_kw
    FROM EV_ANALYTICS.ANALYSIS.V_CHARGER_ENRICHED
    GROUP BY 1
),
joined AS (
    SELECT
        r.sido_nm, r.sigungu_nm, r.sigungu_cd,
        r.ev_cnt, r.population, r.area_km2,
        COALESCE(b.charger_cnt, 0)                      AS charger_cnt,
        COALESCE(b.fast_cnt, 0)                         AS fast_cnt,
        COALESCE(b.total_kw, 0)                         AS total_kw,
        -- 핵심 지표: 충전기 1대당 전기차 대수 (낮을수록 여유)
        ROUND(r.ev_cnt / NULLIF(b.charger_cnt, 0), 1)   AS ev_per_charger,
        ROUND(b.charger_cnt / NULLIF(r.area_km2, 0), 2) AS chargers_per_km2,
        ROUND(1000.0 * b.charger_cnt / NULLIF(r.population, 0), 2) AS chargers_per_1k_pop
    FROM EV_ANALYTICS.ANALYSIS.V_REGION r
    LEFT JOIN by_region b ON b.sigungu_cd = r.sigungu_cd
),
scored AS (
    SELECT j.*,
        -- 전국 중앙값 대비 배수. 1.0 초과 = 전국 평균보다 혼잡(부족)
        ROUND(ev_per_charger / NULLIF(MEDIAN(ev_per_charger) OVER (), 0), 2) AS shortage_index,
        NTILE(5) OVER (ORDER BY ev_per_charger DESC NULLS FIRST)             AS shortage_quintile
    FROM joined j
)
SELECT
    sido_nm AS "시도", sigungu_nm AS "시군구",
    ev_cnt AS "전기차등록", charger_cnt AS "충전기수", fast_cnt AS "급속기수",
    ev_per_charger AS "충전기1대당EV",
    chargers_per_1k_pop AS "인구1천명당충전기",
    chargers_per_km2 AS "km2당충전기",
    shortage_index AS "부족지수",
    CASE shortage_quintile
        WHEN 1 THEN '① 심각 부족' WHEN 2 THEN '② 부족'
        WHEN 3 THEN '③ 보통'     WHEN 4 THEN '④ 여유'
        ELSE '⑤ 충분' END       AS "등급"
FROM scored
ORDER BY shortage_index DESC NULLS LAST;


/* ============================================================================
   3. 공백지 탐지 — H3 격자 기준 "충전기 0대 + 주변에 수요 있음" 셀
      (인접 셀에는 충전기가 있는데 본 셀은 비어있는 구멍을 찾음)
   ============================================================================ */
WITH cells AS (
    SELECT h3_r8 AS cell, COUNT(*) AS charger_cnt, ANY_VALUE(sigungu_cd) AS sigungu_cd
    FROM EV_ANALYTICS.ANALYSIS.V_CHARGER_ENRICHED GROUP BY 1
),
-- 각 셀의 반경 2링(≈5km) 이웃까지 포함한 누적 공급량
ring AS (
    SELECT c.cell,
           c.charger_cnt,
           c.sigungu_cd,
           n.value::VARCHAR AS neighbor_cell
    FROM cells c,
         LATERAL FLATTEN(input => H3_GRID_DISK(c.cell, 2)) n
),
supply AS (
    SELECT r.cell,
           MAX(r.charger_cnt)                       AS own_chargers,
           ANY_VALUE(r.sigungu_cd)                  AS sigungu_cd,
           SUM(COALESCE(c2.charger_cnt, 0))         AS chargers_within_5km
    FROM ring r
    LEFT JOIN cells c2 ON c2.cell = r.neighbor_cell
    GROUP BY 1
)
SELECT
    s.cell                                          AS "h3셀",
    reg.sido_nm AS "시도", reg.sigungu_nm AS "시군구",
    s.own_chargers                                  AS "셀내_충전기",
    s.chargers_within_5km                           AS "반경5km_충전기",
    reg.ev_cnt                                      AS "시군구_전기차수",
    ROUND(reg.ev_cnt / NULLIF(s.chargers_within_5km, 0), 1) AS "권역_EV당충전기부하",
    ST_ASWKT(H3_CELL_TO_POINT(s.cell))              AS "셀중심좌표"
FROM supply s
LEFT JOIN EV_ANALYTICS.ANALYSIS.V_REGION reg ON reg.sigungu_cd = s.sigungu_cd
WHERE s.chargers_within_5km <= 3          -- 광역 공급도 얇은 곳만
  AND reg.ev_cnt >= 500                   -- 수요는 확실히 있는 지역만
ORDER BY "권역_EV당충전기부하" DESC NULLS LAST
LIMIT 100;


/* ============================================================================
   4. 가동률 — 충전기별 실제 이용시간 비율 (최근 30일)
      utilization = 총 충전시간 / 운영가능시간
   ============================================================================ */
WITH win AS (
    SELECT DATEADD(day, -30, CURRENT_DATE()) AS d_from, CURRENT_DATE() AS d_to
),
sess AS (
    SELECT
        s.charger_key,
        COUNT(*)                                                    AS session_cnt,
        SUM(DATEDIFF(minute, s.start_ts, s.end_ts))                 AS busy_min,
        SUM(s.kwh)                                                  AS total_kwh,
        SUM(s.amount_krw)                                           AS revenue_krw,
        AVG(DATEDIFF(minute, s.start_ts, s.end_ts))                 AS avg_session_min
    FROM EV_ANALYTICS.ANALYSIS.V_SESSION s, win w
    WHERE s.start_ts >= w.d_from AND s.start_ts < w.d_to
    GROUP BY 1
)
SELECT
    c.station_nm AS "충전소", c.charger_id AS "충전기", c.speed_tier AS "속도등급",
    c.operator_nm AS "운영사", c.output_kw AS "용량kW", c.status_nm AS "현재상태",
    COALESCE(s.session_cnt, 0)                                      AS "세션수_30일",
    ROUND(COALESCE(s.busy_min, 0) / (30.0 * 24 * 60) * 100, 1)      AS "가동률_pct",
    ROUND(COALESCE(s.total_kwh, 0), 1)                              AS "충전량_kWh",
    ROUND(COALESCE(s.avg_session_min, 0), 0)                        AS "평균세션_분",
    ROUND(COALESCE(s.total_kwh,0) / NULLIF(c.output_kw * 24 * 30, 0) * 100, 2)
                                                                    AS "설비이용률_pct",
    CASE WHEN COALESCE(s.session_cnt,0) = 0            THEN '유휴(사용 0)'
         WHEN COALESCE(s.busy_min,0)/(30.0*24*60) > 0.35 THEN '과포화'
         WHEN COALESCE(s.busy_min,0)/(30.0*24*60) > 0.15 THEN '적정'
         ELSE '저활용' END                                          AS "판정"
FROM EV_ANALYTICS.ANALYSIS.V_CHARGER_ENRICHED c
LEFT JOIN sess s ON s.charger_key = c.charger_key
ORDER BY "가동률_pct" DESC;


/* ============================================================================
   5. 시간대 × 요일 히트맵 — 피크 파악
   ============================================================================ */
SELECT
    DAYNAME(start_ts)                    AS "요일",
    DAYOFWEEK(start_ts)                  AS dow_ord,
    HOUR(start_ts)                       AS "시간대",
    COUNT(*)                             AS "세션수",
    ROUND(SUM(kwh), 0)                   AS "충전량_kWh",
    ROUND(AVG(DATEDIFF(minute, start_ts, end_ts)), 0) AS "평균세션_분",
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS "비중_pct"
FROM EV_ANALYTICS.ANALYSIS.V_SESSION
WHERE start_ts >= DATEADD(day, -90, CURRENT_DATE())
GROUP BY 1, 2, 3
ORDER BY dow_ord, "시간대";


/* ============================================================================
   6. 고장·장애 — 운영사별 신뢰도 (충전소 운영 품질 비교)
   ============================================================================ */
SELECT
    operator_nm                                                     AS "운영사",
    COUNT(*)                                                        AS "충전기수",
    COUNT_IF(status_cd = '1')                                       AS "통신이상",
    COUNT_IF(status_cd = '4')                                       AS "운영중지",
    COUNT_IF(status_cd = '5')                                       AS "점검중",
    ROUND(100.0 * COUNT_IF(status_cd IN ('1','4','5')) / COUNT(*), 2) AS "장애율_pct",
    ROUND(100.0 * COUNT_IF(is_healthy) / COUNT(*), 2)               AS "정상률_pct",
    ROUND(AVG(DATEDIFF(hour, status_upd_ts, CURRENT_TIMESTAMP())), 1) AS "평균_상태갱신경과_h",
    ROUND(AVG(output_kw), 1)                                        AS "평균용량_kW"
FROM EV_ANALYTICS.ANALYSIS.V_CHARGER_ENRICHED
GROUP BY 1
HAVING COUNT(*) >= 20
ORDER BY "장애율_pct" DESC;


/* ============================================================================
   7. 설치장소 유형별 효율 — 어떤 장소가 잘 쓰이나
   ============================================================================ */
WITH s AS (
    SELECT charger_key, COUNT(*) cnt, SUM(kwh) kwh
    FROM EV_ANALYTICS.ANALYSIS.V_SESSION WHERE start_ts >= DATEADD(day, -30, CURRENT_DATE())
    GROUP BY 1
)
SELECT
    c.place_kind_cd                                     AS "설치장소코드",
    c.speed_tier                                        AS "속도등급",
    COUNT(*)                                            AS "충전기수",
    ROUND(AVG(COALESCE(s.cnt, 0)), 1)                   AS "대당_월평균세션",
    ROUND(AVG(COALESCE(s.kwh, 0)), 1)                   AS "대당_월평균kWh",
    ROUND(100.0 * COUNT_IF(COALESCE(s.cnt,0) = 0) / COUNT(*), 1) AS "유휴비율_pct",
    ROUND(100.0 * COUNT_IF(c.parking_free_yn = 'Y') / COUNT(*), 1) AS "주차무료_pct"
FROM EV_ANALYTICS.ANALYSIS.V_CHARGER_ENRICHED c
LEFT JOIN s ON s.charger_key = c.charger_key
GROUP BY 1, 2
ORDER BY "대당_월평균세션" DESC;


/* ============================================================================
   8. ★ 신규 입지 추천 스코어링
      점수 = 수요갭(40) + 혼잡도(30) + 급속부재(20) + 접근성(10)
      가중치는 아래 CTE의 숫자만 바꾸면 됩니다.
   ============================================================================ */
WITH cell_supply AS (
    SELECT h3_r8 AS cell,
           ANY_VALUE(sigungu_cd)                         AS sigungu_cd,
           COUNT(*)                                      AS charger_cnt,
           COUNT_IF(speed_tier IN ('급속','초급속'))      AS fast_cnt,
           SUM(output_kw)                                AS kw_sum,
           COUNT(DISTINCT operator_nm)                   AS operator_cnt
    FROM EV_ANALYTICS.ANALYSIS.V_CHARGER_ENRICHED
    GROUP BY 1
),
cell_demand AS (
    SELECT cs.cell, cs.sigungu_cd, cs.charger_cnt, cs.fast_cnt, cs.kw_sum, cs.operator_cnt,
           r.sido_nm, r.sigungu_nm, r.ev_cnt, r.population,
           -- 시군구 EV를 해당 시군구 셀 수로 안분한 셀 단위 추정 수요
           r.ev_cnt / NULLIF(COUNT(*) OVER (PARTITION BY cs.sigungu_cd), 0) AS est_ev_in_cell
    FROM cell_supply cs
    LEFT JOIN EV_ANALYTICS.ANALYSIS.V_REGION r ON r.sigungu_cd = cs.sigungu_cd
),
util AS (   -- 세션 데이터 없으면 이 CTE와 congestion_score를 0으로 두세요
    SELECT c.h3_r8 AS cell,
           AVG(COALESCE(x.busy_min, 0) / (30.0 * 24 * 60)) AS avg_util
    FROM EV_ANALYTICS.ANALYSIS.V_CHARGER_ENRICHED c
    LEFT JOIN (
        SELECT charger_key, SUM(DATEDIFF(minute, start_ts, end_ts)) AS busy_min
        FROM EV_ANALYTICS.ANALYSIS.V_SESSION WHERE start_ts >= DATEADD(day, -30, CURRENT_DATE())
        GROUP BY 1
    ) x ON x.charger_key = c.charger_key
    GROUP BY 1
),
scored AS (
    SELECT
        d.*,
        COALESCE(u.avg_util, 0) AS avg_util,
        -- ① 수요갭: 셀 추정 EV 대비 충전기 부족 (0~40)
        40 * LEAST(1, (d.est_ev_in_cell / NULLIF(d.charger_cnt, 0)) / 50.0)      AS s_demand,
        -- ② 혼잡도: 기존 충전기 평균 가동률 (0~30). 0.35 이상이면 만점
        30 * LEAST(1, COALESCE(u.avg_util, 0) / 0.35)                            AS s_congestion,
        -- ③ 급속 부재: 급속기 비중이 낮을수록 가점 (0~20)
        20 * (1 - LEAST(1, d.fast_cnt / NULLIF(d.charger_cnt, 0)))               AS s_fastgap,
        -- ④ 접근성/경쟁: 운영사 1곳 독점이면 가점 (0~10)
        10 * (1.0 / NULLIF(d.operator_cnt, 0))                                   AS s_access
    FROM cell_demand d
    LEFT JOIN util u ON u.cell = d.cell
)
SELECT
    cell                                        AS "h3셀",
    sido_nm AS "시도", sigungu_nm AS "시군구",
    ROUND(est_ev_in_cell, 0)                    AS "추정EV대수",
    charger_cnt AS "기존충전기", fast_cnt AS "기존급속",
    ROUND(avg_util * 100, 1)                    AS "기존가동률_pct",
    ROUND(s_demand, 1)  AS "수요갭점수",
    ROUND(s_congestion, 1) AS "혼잡점수",
    ROUND(s_fastgap, 1) AS "급속부재점수",
    ROUND(s_access, 1)  AS "접근성점수",
    ROUND(s_demand + s_congestion + s_fastgap + s_access, 1) AS "종합점수",
    CASE WHEN s_demand + s_congestion + s_fastgap + s_access >= 70 THEN 'A — 즉시 검토'
         WHEN s_demand + s_congestion + s_fastgap + s_access >= 50 THEN 'B — 우선순위 높음'
         WHEN s_demand + s_congestion + s_fastgap + s_access >= 30 THEN 'C — 관찰'
         ELSE 'D — 보류' END                    AS "등급",
    ST_ASWKT(H3_CELL_TO_POINT(cell))            AS "중심좌표"
FROM scored
WHERE est_ev_in_cell >= 100
ORDER BY "종합점수" DESC
LIMIT 50;


/* ============================================================================
   9. 대시보드 적재용 — 위 결과를 테이블로 저장 (BI 연결 시)
   ============================================================================ */
-- CREATE OR REPLACE TABLE MART_EV_REGION_COVERAGE AS ( 2번 쿼리 본문 );
-- CREATE OR REPLACE TABLE MART_EV_SITE_CANDIDATE  AS ( 8번 쿼리 본문 );
-- CREATE OR REPLACE TABLE MART_EV_UTILIZATION     AS ( 4번 쿼리 본문 );


/* ============================================================================
   [참고] 코드값 — 환경공단 기준
   status_cd  1 통신이상 · 2 충전대기 · 3 충전중 · 4 운영중지 · 5 점검중 · 9 미확인
   chger_type 01 DC차데모 · 02 AC완속 · 03 DC차데모+AC3상 · 04 DC콤보
              05 DC차데모+DC콤보 · 06 DC차데모+AC3상+DC콤보 · 07 AC3상 · 08 DC콤보(초급속)
   H3 해상도  r7 ≈ 반경 2.6km · r8 ≈ 반경 1.0km · r9 ≈ 반경 0.4km
   ============================================================================ */
