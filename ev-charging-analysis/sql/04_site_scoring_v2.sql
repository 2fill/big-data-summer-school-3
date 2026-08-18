/* ============================================================================
   8b. 신규 입지 추천 — 개선판 (v2)
   ----------------------------------------------------------------------------
   v1의 문제와 수정 내용
     ① 분모가 1인 셀이 자동 만점  →  셀 단위 나눗셈 제거.
        셀 하나가 아니라 "권역"(중심셀 + 인접 6셀, 약 3km 폭)을 분석 단위로 사용.
     ② 시군구 EV를 셀에 균등 안분  →  안분 자체를 수요 지표에서 배제.
        지역 부하는 시군구 단위로만 쓰고, 셀 단위 수요는 실제 세션 실적으로 대체.
     ③ 수요 없는 외딴 셀이 상위 진입  →  권역 충전기 3대 이상 + 세션 100건 이상만 후보.
        (수요가 실증된 곳에만 증설하겠다는 뜻)
     ④ 상위권이 서로 인접한 중복 셀  →  시군구당 최대 2곳으로 제한.

   점수 = 지역부하(35) + 권역혼잡(30) + 급속부재(20) + 권역희소(15)
   ============================================================================ */

WITH cell_base AS (
    SELECT
        c.h3_r8                                          AS cell,
        ANY_VALUE(c.sigungu_cd)                          AS sigungu_cd,
        COUNT(*)                                         AS charger_cnt,
        COUNT_IF(c.speed_tier IN ('급속','초급속'))       AS fast_cnt,
        SUM(c.output_kw)                                 AS kw_sum,
        COUNT(DISTINCT c.operator_nm)                    AS operator_cnt,
        SUM(COALESCE(s.session_cnt, 0))                  AS session_cnt,
        SUM(COALESCE(s.busy_min, 0))                     AS busy_min,
        SUM(COALESCE(s.kwh, 0))                          AS kwh_sum,
        COUNT(*) * 30.0 * 24 * 60                        AS avail_min
    FROM EV_ANALYTICS.ANALYSIS.V_CHARGER_ENRICHED c
    LEFT JOIN (
        SELECT charger_key,
               COUNT(*)                                  AS session_cnt,
               SUM(DATEDIFF(minute, start_ts, end_ts))   AS busy_min,
               SUM(kwh)                                  AS kwh
        FROM EV_ANALYTICS.ANALYSIS.V_SESSION
        WHERE start_ts >= DATEADD(day, -30, CURRENT_DATE())
        GROUP BY 1
    ) s ON s.charger_key = c.charger_key
    GROUP BY 1
),

/* 각 셀의 권역(자기 자신 + 인접 6셀) 목록 */
ring AS (
    SELECT b.cell           AS center,
           n.value::VARCHAR AS member
    FROM cell_base b,
         LATERAL FLATTEN(input => H3_GRID_DISK(b.cell, 1)) n
),

/* 권역 단위로 공급·수요를 합산 — 셀 하나만 보던 v1의 편향 제거 */
zone AS (
    SELECT
        r.center                                          AS cell,
        ANY_VALUE(b0.sigungu_cd)                          AS sigungu_cd,
        SUM(COALESCE(m.charger_cnt, 0))                   AS z_chargers,
        SUM(COALESCE(m.fast_cnt, 0))                      AS z_fast,
        SUM(COALESCE(m.kw_sum, 0))                        AS z_kw,
        SUM(COALESCE(m.session_cnt, 0))                   AS z_sessions,
        SUM(COALESCE(m.kwh_sum, 0))                       AS z_kwh,
        SUM(COALESCE(m.busy_min, 0))                      AS z_busy,
        SUM(COALESCE(m.avail_min, 0))                     AS z_avail,
        MAX(COALESCE(m.operator_cnt, 0))                  AS z_operators
    FROM ring r
    JOIN cell_base b0 ON b0.cell = r.center
    LEFT JOIN cell_base m ON m.cell = r.member
    GROUP BY 1
),

/* 시군구 단위 부하 — 셀 안분을 쓰지 않는 유일한 수요 지표 */
region_load AS (
    SELECT
        r.sigungu_cd, r.sido_nm, r.sigungu_nm, r.ev_cnt,
        COUNT(c.charger_key)                              AS reg_chargers,
        r.ev_cnt / NULLIF(COUNT(c.charger_key), 0)        AS ev_per_charger
    FROM EV_ANALYTICS.ANALYSIS.V_REGION r
    LEFT JOIN EV_ANALYTICS.ANALYSIS.V_CHARGER_ENRICHED c
           ON c.sigungu_cd = r.sigungu_cd
    GROUP BY 1,2,3,4
),

candidate AS (
    SELECT
        z.cell, z.z_chargers, z.z_fast, z.z_kw, z.z_sessions, z.z_kwh,
        rl.sido_nm, rl.sigungu_nm, rl.ev_cnt, rl.ev_per_charger,
        z.z_busy / NULLIF(z.z_avail, 0)                   AS z_util,
        z.z_kwh  / NULLIF(z.z_kw * 24 * 30, 0)            AS z_kw_util,
        z.z_sessions / NULLIF(z.z_chargers, 0) / 30.0     AS sessions_per_charger_day
    FROM zone z
    JOIN region_load rl ON rl.sigungu_cd = z.sigungu_cd
    WHERE z.z_chargers >= 3        -- 수요가 실증된 권역만
      AND z.z_sessions >= 100      -- 최근 30일 세션 100건 이상
),

scored AS (
    SELECT c.*,
        /* ① 지역 부하 (35점) — 시군구 EV/충전기. 60대 이상이면 만점 */
        35 * LEAST(1, c.ev_per_charger / 60.0)                        AS s_region,
        /* ② 권역 혼잡 (30점) — 권역 평균 시간 점유율. 15% 이상이면 만점 */
        30 * LEAST(1, COALESCE(c.z_util, 0) / 0.15)                   AS s_congestion,
        /* ③ 급속 부재 (20점) — 권역 급속 비중이 낮을수록 가점 */
        20 * (1 - LEAST(1, c.z_fast / NULLIF(c.z_chargers, 0) / 0.5)) AS s_fastgap,
        /* ④ 권역 희소 (15점) — 권역 충전기 15대 이하면 만점, 60대 이상이면 0 */
        15 * LEAST(1, GREATEST(0, (60 - c.z_chargers) / 45.0))        AS s_sparse
    FROM candidate c
),

ranked AS (
    SELECT s.*,
        ROUND(s_region + s_congestion + s_fastgap + s_sparse, 1) AS total_score
    FROM scored s
    /* 인접 셀 중복 제거 — 시군구당 최대 2곳 */
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY sigungu_nm
        ORDER BY s_region + s_congestion + s_fastgap + s_sparse DESC
    ) <= 2
)

SELECT
    ROW_NUMBER() OVER (ORDER BY total_score DESC)     AS "순위",
    sido_nm                                           AS "시도",
    sigungu_nm                                        AS "시군구",
    cell                                              AS "h3셀",
    z_chargers                                        AS "권역_충전기",
    z_fast                                            AS "권역_급속",
    ROUND(100.0 * z_fast / NULLIF(z_chargers,0), 0)   AS "급속비중_pct",
    z_sessions                                        AS "권역_세션_30일",
    ROUND(sessions_per_charger_day, 2)                AS "대당_일평균세션",
    ROUND(z_util * 100, 1)                            AS "권역_가동률_pct",
    ROUND(ev_per_charger, 1)                          AS "시군구_1대당EV",
    ROUND(s_region, 1)                                AS "지역부하점수",
    ROUND(s_congestion, 1)                            AS "권역혼잡점수",
    ROUND(s_fastgap, 1)                               AS "급속부재점수",
    ROUND(s_sparse, 1)                                AS "권역희소점수",
    total_score                                       AS "종합점수",
    CASE WHEN total_score >= 70 THEN 'A — 즉시 검토'
         WHEN total_score >= 55 THEN 'B — 우선순위 높음'
         WHEN total_score >= 40 THEN 'C — 관찰'
         ELSE 'D — 보류' END                          AS "등급",
    ST_ASWKT(H3_CELL_TO_POINT(cell))                  AS "중심좌표"
FROM ranked
ORDER BY total_score DESC
LIMIT 20;
