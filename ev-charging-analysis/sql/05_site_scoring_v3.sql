/* ============================================================================
   8d. 신규 입지 추천 — v3 (2트랙 + 분위 정규화)
   ----------------------------------------------------------------------------
   v2의 문제와 수정 내용
     ① 제주시·구미시(부하 1·2위)가 필터에서 탈락
        → 원인: "권역 충전기 3대 + 세션 100건" 필터가 저밀도 지역을 구조적으로 배제.
        → 수정: 필터를 후보 배제가 아니라 트랙 구분에 사용.
                · 혼잡형(BROWNFIELD) = 이미 충전기가 있고 붐비는 권역 → 증설
                · 공백형(GREENFIELD)  = 충전기가 희박한 권역 → 신규 진입
                두 트랙을 따로 순위 매겨 각각 제시. 성격이 다른 투자라 섞으면 안 됨.

     ② 권역희소 85%가 만점, 권역혼잡은 30점 중 7~12점만 사용 → 배점이 죽음
        → 원인: 고정 임계값(15대, 0.15)이 실제 데이터 분포와 안 맞음.
        → 수정: 모든 구성요소를 PERCENT_RANK로 후보군 내 분위(0~1)로 환산.
                임계값 추측이 필요 없고, 각 배점이 항상 0~만점 전 구간을 사용함.

   점수 = 지역부하(35) + 권역혼잡(25) + 급속부재(20) + 공급희소(20)
   ============================================================================ */

WITH cell_base AS (
    SELECT c.h3_r8 AS cell, ANY_VALUE(c.sigungu_cd) AS sigungu_cd,
           COUNT(*)                                  AS charger_cnt,
           COUNT_IF(c.speed_tier IN ('급속','초급속')) AS fast_cnt,
           SUM(c.output_kw)                          AS kw_sum,
           SUM(COALESCE(s.session_cnt,0))            AS session_cnt,
           SUM(COALESCE(s.busy_min,0))               AS busy_min,
           COUNT(*) * 30.0 * 24 * 60                 AS avail_min
    FROM EV_ANALYTICS.ANALYSIS.V_CHARGER_ENRICHED c
    LEFT JOIN (
        SELECT charger_key, COUNT(*) AS session_cnt,
               SUM(DATEDIFF(minute, start_ts, end_ts)) AS busy_min
        FROM EV_ANALYTICS.ANALYSIS.V_SESSION
        WHERE start_ts >= DATEADD(day,-30,CURRENT_DATE()) GROUP BY 1
    ) s ON s.charger_key = c.charger_key
    GROUP BY 1
),
ring AS (
    SELECT b.cell AS center, n.value::VARCHAR AS member
    FROM cell_base b, LATERAL FLATTEN(input => H3_GRID_DISK(b.cell, 1)) n
),
zone AS (
    SELECT r.center AS cell, ANY_VALUE(b0.sigungu_cd) AS sigungu_cd,
           SUM(COALESCE(m.charger_cnt,0)) AS z_chargers,
           SUM(COALESCE(m.fast_cnt,0))    AS z_fast,
           SUM(COALESCE(m.kw_sum,0))      AS z_kw,
           SUM(COALESCE(m.session_cnt,0)) AS z_sessions,
           SUM(COALESCE(m.busy_min,0))    AS z_busy,
           SUM(COALESCE(m.avail_min,0))   AS z_avail
    FROM ring r
    JOIN cell_base b0 ON b0.cell = r.center
    LEFT JOIN cell_base m ON m.cell = r.member
    GROUP BY 1
),
region_load AS (
    SELECT r.sigungu_cd, r.sido_nm, r.sigungu_nm, r.ev_cnt,
           r.ev_cnt / NULLIF(COUNT(c.charger_key),0) AS ev_per_charger
    FROM EV_ANALYTICS.ANALYSIS.V_REGION r
    LEFT JOIN EV_ANALYTICS.ANALYSIS.V_CHARGER_ENRICHED c ON c.sigungu_cd = r.sigungu_cd
    GROUP BY 1,2,3,4
),

/* 후보: 전기차 수요가 있는 지역 전체. 저밀도 지역을 배제하지 않는다. */
candidate AS (
    SELECT z.cell, z.z_chargers, z.z_fast, z.z_kw, z.z_sessions,
           rl.sido_nm, rl.sigungu_nm, rl.ev_cnt, rl.ev_per_charger,
           COALESCE(z.z_busy / NULLIF(z.z_avail,0), 0)        AS z_util,
           z.z_fast / NULLIF(z.z_chargers,0)                  AS fast_ratio,
           CASE WHEN z.z_sessions >= 100 AND z.z_chargers >= 3
                THEN '혼잡형' ELSE '공백형' END                AS track
    FROM zone z
    JOIN region_load rl ON rl.sigungu_cd = z.sigungu_cd
    WHERE rl.ev_cnt >= 200
),

/* 각 구성요소를 트랙 내 분위(0~1)로 환산 — 고정 임계값 제거 */
pct AS (
    SELECT c.*,
        PERCENT_RANK() OVER (PARTITION BY track ORDER BY ev_per_charger)          AS p_region,
        PERCENT_RANK() OVER (PARTITION BY track ORDER BY z_util)                  AS p_cong,
        PERCENT_RANK() OVER (PARTITION BY track ORDER BY COALESCE(fast_ratio,0) DESC) AS p_fast,
        PERCENT_RANK() OVER (PARTITION BY track ORDER BY z_chargers DESC)         AS p_sparse
    FROM candidate c
),
scored AS (
    SELECT p.*,
        ROUND(35 * p_region, 1)  AS s_region,
        ROUND(25 * p_cong,   1)  AS s_cong,
        ROUND(20 * p_fast,   1)  AS s_fast,
        ROUND(20 * p_sparse, 1)  AS s_sparse,
        ROUND(35*p_region + 25*p_cong + 20*p_fast + 20*p_sparse, 1) AS total_score
    FROM pct p
),
ranked AS (
    SELECT s.* FROM scored s
    /* 인접 중복 제거 — 트랙별로 시군구당 최대 2곳 */
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY track, sigungu_nm ORDER BY total_score DESC) <= 2
)

SELECT
    track                                             AS "트랙",
    ROW_NUMBER() OVER (PARTITION BY track ORDER BY total_score DESC) AS "순위",
    sido_nm                                           AS "시도",
    sigungu_nm                                        AS "시군구",
    cell                                              AS "h3셀",
    z_chargers                                        AS "권역_충전기",
    z_fast                                            AS "권역_급속",
    z_sessions                                        AS "권역_세션_30일",
    ROUND(z_util * 100, 1)                            AS "권역_가동률_pct",
    ROUND(ev_per_charger, 1)                          AS "시군구_1대당EV",
    s_region                                          AS "지역부하점수",
    s_cong                                            AS "권역혼잡점수",
    s_fast                                            AS "급속부재점수",
    s_sparse                                          AS "공급희소점수",
    total_score                                       AS "종합점수",
    CASE WHEN total_score >= 70 THEN 'A — 즉시 검토'
         WHEN total_score >= 55 THEN 'B — 우선순위 높음'
         WHEN total_score >= 40 THEN 'C — 관찰'
         ELSE 'D — 보류' END                          AS "등급",
    ST_ASWKT(H3_CELL_TO_POINT(cell))                  AS "중심좌표"
FROM ranked
QUALIFY ROW_NUMBER() OVER (PARTITION BY track ORDER BY total_score DESC) <= 10
ORDER BY track, total_score DESC;
