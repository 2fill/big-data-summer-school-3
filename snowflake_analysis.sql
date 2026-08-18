-- ============================================================================
-- 전기차 충전 인프라 갭 분석 - Snowflake SQL 재현
-- snowflake_upload.py로 5개 테이블 적재 완료 후 실행
-- 지금까지 Python(pandas)으로 했던 분석을 SQL로 재현 (가설검증 SQL 산출물)
-- ============================================================================

USE DATABASE PROJECT;
USE SCHEMA EV;

-- ----------------------------------------------------------------------------
-- STEP 1. 회귀 잔차 계산 (등록대수만으로 - 2단계 베이스라인)
-- Snowflake는 REGR_SLOPE/REGR_INTERCEPT/REGR_R2가 SQL 집계함수로 내장되어 있어
-- Python SimpleOLS 없이 SQL 한 방으로 단순회귀를 재현할 수 있음
-- ----------------------------------------------------------------------------
WITH base AS (
    SELECT *, LN(REGISTRATION) AS LOG_REG
    FROM EV_REGISTRATION_SIGUNGU
),
reg_stats AS (
    SELECT
        REGR_SLOPE(TOTAL_CHARGERS, LOG_REG) AS SLOPE,
        REGR_INTERCEPT(TOTAL_CHARGERS, LOG_REG) AS INTERCEPT,
        REGR_R2(TOTAL_CHARGERS, LOG_REG) AS R2
    FROM base
)
SELECT
    b.SIDO, b.SIGUNGU, b.REGISTRATION, b.TOTAL_CHARGERS,
    ROUND(r.SLOPE * b.LOG_REG + r.INTERCEPT, 1) AS EXPECTED_TOTAL,
    ROUND(b.TOTAL_CHARGERS - (r.SLOPE * b.LOG_REG + r.INTERCEPT), 1) AS RESID_TOTAL,
    r.R2 AS MODEL_R2
FROM base b
CROSS JOIN reg_stats r
ORDER BY RESID_TOTAL ASC
LIMIT 20;
-- -> 잔차 하위 20 (2단계 결과 재현). MODEL_R2가 전체 행에 동일하게 붙어 나오는데,
--    이게 파이썬에서 구했던 R²=0.509와 일치하는지 확인하는 게 첫 검증 포인트.


-- ----------------------------------------------------------------------------
-- STEP 2. 완속/급속 분리 잔차 (뷰로 만들어두면 이후 단계에서 재사용 편함)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_RESIDUALS AS
WITH base AS (
    SELECT *, LN(REGISTRATION) AS LOG_REG
    FROM EV_REGISTRATION_SIGUNGU
),
stats_total AS (
    SELECT REGR_SLOPE(TOTAL_CHARGERS, LOG_REG) AS SLOPE, REGR_INTERCEPT(TOTAL_CHARGERS, LOG_REG) AS INTERCEPT
    FROM base
),
stats_fast AS (
    SELECT REGR_SLOPE(FAST_CHARGERS, LOG_REG) AS SLOPE, REGR_INTERCEPT(FAST_CHARGERS, LOG_REG) AS INTERCEPT
    FROM base
),
stats_slow AS (
    SELECT REGR_SLOPE(SLOW_CHARGERS, LOG_REG) AS SLOPE, REGR_INTERCEPT(SLOW_CHARGERS, LOG_REG) AS INTERCEPT
    FROM base
)
SELECT
    b.SIDO, b.SIGUNGU, b.REGISTRATION, b.LOG_REG,
    b.TOTAL_CHARGERS, b.FAST_CHARGERS, b.SLOW_CHARGERS,
    b.TOTAL_CHARGERS - (t.SLOPE * b.LOG_REG + t.INTERCEPT) AS RESID_TOTAL,
    b.FAST_CHARGERS  - (f.SLOPE * b.LOG_REG + f.INTERCEPT) AS RESID_FAST,
    b.SLOW_CHARGERS  - (s.SLOPE * b.LOG_REG + s.INTERCEPT) AS RESID_SLOW
FROM base b
CROSS JOIN stats_total t
CROSS JOIN stats_fast f
CROSS JOIN stats_slow s;

-- 완속만 특히 부족한 9개도시 재현
SELECT SIGUNGU, RESID_FAST, RESID_SLOW
FROM V_RESIDUALS
WHERE SIGUNGU IN ('아산시','천안시 동남구','여수시','순천시','광양시',
                   '포항시 남구','포항시 북구','영천시','경산시')
ORDER BY RESID_SLOW;


-- ----------------------------------------------------------------------------
-- STEP 3. 9개 도시 vs 전국 - 주택지표 비교 (3단계 재현)
-- ----------------------------------------------------------------------------
SELECT
    CASE WHEN h.SIGUNGU IN ('아산시','천안시 동남구','여수시','순천시','광양시',
                             '포항시 남구','포항시 북구','영천시','경산시')
         THEN '9개도시' ELSE '전국(그외)' END AS GROUP_LABEL,
    ROUND(AVG(h.APT_RATIO), 1) AS AVG_APT_RATIO,
    ROUND(AVG(h.OLD_HOUSING_RATIO), 1) AS AVG_OLD_HOUSING_RATIO,
    COUNT(*) AS N
FROM HOUSING_INDICATORS h
GROUP BY GROUP_LABEL;
-- -> 9개도시 아파트비율이 "전국(그외)"보다 높게 나오는지 확인 (당연한 설명 기각 재현)

-- 부산4구 vs 전국 - 노후비율/주차장확보율
SELECT
    CASE WHEN h.SIDO = '부산' AND h.SIGUNGU IN ('수영구','연제구','중구','동구')
         THEN '부산4구' ELSE '전국(그외)' END AS GROUP_LABEL,
    ROUND(AVG(h.OLD_HOUSING_RATIO), 1) AS AVG_OLD_HOUSING_RATIO,
    ROUND(AVG(h.PARKING_SECURED_RATIO), 1) AS AVG_PARKING_RATIO,
    COUNT(*) AS N
FROM HOUSING_INDICATORS h
GROUP BY GROUP_LABEL;


-- ----------------------------------------------------------------------------
-- STEP 4. 보조금 - 전체표본 상관관계 (5단계 null 결과 재현)
-- Snowflake CORR() 집계함수로 Pearson 상관계수 바로 계산 가능
-- 주의: SUBSIDY_REGION은 시/광역시 단위라 시군구와 바로 조인 안 됨.
--       파이썬 subsidy_lookup_key()와 동일한 로직: 광역시 관할구/다구도시 관할구는
--       상위 도시명으로 매핑키를 만들어서 조인 (METRO 7개 + MULTI_GU 11개)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW V_SUBSIDY_JOIN_KEY AS
SELECT
    v.*,
    CASE v.SIDO
        WHEN '서울' THEN '서울특별시' WHEN '부산' THEN '부산광역시' WHEN '대구' THEN '대구광역시'
        WHEN '인천' THEN '인천광역시' WHEN '광주' THEN '광주광역시' WHEN '대전' THEN '대전광역시'
        WHEN '울산' THEN '울산광역시'
        WHEN '경기' THEN
            CASE
                WHEN v.SIGUNGU LIKE '수원시%' THEN '수원시' WHEN v.SIGUNGU LIKE '성남시%' THEN '성남시'
                WHEN v.SIGUNGU LIKE '안산시%' THEN '안산시' WHEN v.SIGUNGU LIKE '안양시%' THEN '안양시'
                WHEN v.SIGUNGU LIKE '용인시%' THEN '용인시' WHEN v.SIGUNGU LIKE '고양시%' THEN '고양시'
                ELSE v.SIGUNGU
            END
        WHEN '경남' THEN CASE WHEN v.SIGUNGU LIKE '창원시%' THEN '창원시' ELSE v.SIGUNGU END
        WHEN '충북' THEN CASE WHEN v.SIGUNGU LIKE '청주시%' THEN '청주시' ELSE v.SIGUNGU END
        WHEN '충남' THEN CASE WHEN v.SIGUNGU LIKE '천안시%' THEN '천안시' ELSE v.SIGUNGU END
        WHEN '전북' THEN CASE WHEN v.SIGUNGU LIKE '전주시%' THEN '전주시' ELSE v.SIGUNGU END
        WHEN '경북' THEN CASE WHEN v.SIGUNGU LIKE '포항시%' THEN '포항시' ELSE v.SIGUNGU END
        ELSE v.SIGUNGU
    END AS SUBSIDY_LOOKUP_REGION
FROM V_RESIDUALS v;

SELECT
    CORR(j.RESID_TOTAL, s.APPLICATION_RATE_PCT) AS CORR_RESID_VS_APPLICATION_RATE,
    CORR(j.RESID_TOTAL, s.BUDGET_USED_PCT) AS CORR_RESID_VS_BUDGET_USED,
    COUNT(*) AS N
FROM V_SUBSIDY_JOIN_KEY j
JOIN SUBSIDY_REGION s
  ON j.SIDO = s.SIDO AND j.SUBSIDY_LOOKUP_REGION = s.REGION_NAME;
-- -> 파이썬에서 나온 rho=-0.04~-0.08, 비유의 결과와 방향이 비슷한지 확인
--    (Snowflake CORR은 Pearson이라 파이썬 Spearman과 정확히 값은 다를 수 있음에 주의,
--     N도 파이썬 결과(247)와 비슷하게 나오는지 꼭 확인 - 크게 다르면 매핑 로직 점검)


-- ----------------------------------------------------------------------------
-- STEP 5. 인구 정규화 (6단계 재현)
-- ----------------------------------------------------------------------------
SELECT
    v.SIDO, v.SIGUNGU,
    p.POPULATION,
    ROUND(v.REGISTRATION / p.POPULATION * 10000, 1) AS REGISTRATION_PER_10K,
    v.RESID_SLOW
FROM V_RESIDUALS v
JOIN POPULATION_SIGUNGU p ON v.SIDO = p.SIDO AND v.SIGUNGU = p.SIGUNGU
WHERE v.SIGUNGU IN ('아산시','천안시 동남구','여수시','순천시','광양시',
                     '포항시 남구','포항시 북구','영천시','경산시')
   OR (v.SIDO = '부산' AND v.SIGUNGU IN ('수영구','연제구','중구','동구'))
ORDER BY REGISTRATION_PER_10K DESC;


-- ----------------------------------------------------------------------------
-- STEP 6. 모델(다변량) 결과 - 설치 우선순위 Top 20 (Streamlit 대시보드용 최종 쿼리)
-- ----------------------------------------------------------------------------
SELECT SIDO, SIGUNGU, REGISTRATION, TOTAL_CHARGERS,
       EXPECTED_TOTAL_MULTIVAR, INSTALL_PRIORITY_SCORE
FROM INSTALL_PRIORITY_MODEL
ORDER BY INSTALL_PRIORITY_SCORE DESC
LIMIT 20;
