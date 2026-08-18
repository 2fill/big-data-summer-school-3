/* ============================================================================
   9. 대시보드 적재용 EXPORT — 모든 지표를 JSON 한 칸으로 출력
   실행 후 결과 셀 1개를 통째로 복사해서 전달하면 대시보드에 실제 수치가 반영됩니다.
   ============================================================================ */

WITH kpi AS (
    SELECT OBJECT_CONSTRUCT(
        'total_chargers',  COUNT(*),
        'total_stations',  COUNT(DISTINCT station_id),
        'fast_chargers',   COUNT_IF(speed_tier IN ('급속','초급속')),
        'fast_pct',        ROUND(100.0 * COUNT_IF(speed_tier IN ('급속','초급속')) / NULLIF(COUNT(*),0), 1),
        'healthy_pct',     ROUND(100.0 * COUNT_IF(is_healthy) / NULLIF(COUNT(*),0), 1),
        'faulty',          COUNT_IF(status_cd IN ('1','4','5')),
        'operators',       COUNT(DISTINCT operator_nm),
        'total_mw',        ROUND(SUM(output_kw)/1000, 1)
    ) AS o
    FROM EV_ANALYTICS.ANALYSIS.V_CHARGER_ENRICHED
),

/* ---- 커버리지 ---- */
cov_base AS (
    SELECT sigungu_cd,
           COUNT(*) AS charger_cnt,
           COUNT_IF(speed_tier IN ('급속','초급속')) AS fast_cnt
    FROM EV_ANALYTICS.ANALYSIS.V_CHARGER_ENRICHED GROUP BY 1
),
cov_join AS (
    SELECT r.sido_nm, r.sigungu_nm, r.ev_cnt,
           COALESCE(b.charger_cnt,0) AS charger_cnt,
           COALESCE(b.fast_cnt,0)    AS fast_cnt,
           ROUND(r.ev_cnt / NULLIF(b.charger_cnt,0), 1) AS ev_per_charger
    FROM EV_ANALYTICS.ANALYSIS.V_REGION r
    LEFT JOIN cov_base b ON b.sigungu_cd = r.sigungu_cd
),
cov_ranked AS (
    SELECT sido_nm, sigungu_nm, ev_cnt, charger_cnt, fast_cnt, ev_per_charger,
           ROUND(ev_per_charger / NULLIF(MEDIAN(ev_per_charger) OVER (), 0), 2) AS idx,
           NTILE(5) OVER (ORDER BY ev_per_charger DESC NULLS FIRST)             AS q
    FROM cov_join
),
cov AS (
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(
        'sido', sido_nm, 'sigungu', sigungu_nm, 'ev', ev_cnt,
        'chargers', charger_cnt, 'fast', fast_cnt,
        'ev_per_charger', ev_per_charger,
        'idx', idx, 'q', q
    )) WITHIN GROUP (ORDER BY ev_per_charger DESC NULLS FIRST) AS a
    FROM cov_ranked
),

/* ---- 요일 × 시간대 ---- */
heat AS (
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT('dow', dow, 'hour', hr, 'n', cnt))
           WITHIN GROUP (ORDER BY dow, hr) AS a
    FROM (
        SELECT DAYOFWEEKISO(start_ts) AS dow, HOUR(start_ts) AS hr, COUNT(*) AS cnt
        FROM EV_ANALYTICS.ANALYSIS.V_SESSION
        WHERE start_ts >= DATEADD(day, -90, CURRENT_DATE())
        GROUP BY 1,2
    )
),

/* ---- 속도등급별 가동률 ---- */
util AS (
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT('tier', tier, 'kw', kw, 'n', n, 'util', util))
           WITHIN GROUP (ORDER BY util DESC) AS a
    FROM (
        SELECT c.speed_tier AS tier,
               ROUND(AVG(c.output_kw),0) AS kw,
               COUNT(*) AS n,
               ROUND(AVG(COALESCE(s.busy_min,0) / (30.0*24*60)) * 100, 1) AS util
        FROM EV_ANALYTICS.ANALYSIS.V_CHARGER_ENRICHED c
        LEFT JOIN (
            SELECT charger_key, SUM(DATEDIFF(minute, start_ts, end_ts)) AS busy_min
            FROM EV_ANALYTICS.ANALYSIS.V_SESSION
            WHERE start_ts >= DATEADD(day,-30,CURRENT_DATE()) GROUP BY 1
        ) s ON s.charger_key = c.charger_key
        GROUP BY 1
    )
),

/* ---- 운영사 ---- */
ops AS (
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(
        'op', operator_nm, 'n', n, 'comm', comm, 'stop', stopped,
        'maint', maint, 'fault_pct', fault_pct, 'avg_kw', avg_kw))
        WITHIN GROUP (ORDER BY fault_pct DESC) AS a
    FROM (
        SELECT operator_nm,
               COUNT(*) AS n,
               COUNT_IF(status_cd='1') AS comm,
               COUNT_IF(status_cd='4') AS stopped,
               COUNT_IF(status_cd='5') AS maint,
               ROUND(100.0*COUNT_IF(status_cd IN ('1','4','5'))/COUNT(*),1) AS fault_pct,
               ROUND(AVG(output_kw),1) AS avg_kw
        FROM EV_ANALYTICS.ANALYSIS.V_CHARGER_ENRICHED
        GROUP BY 1 HAVING COUNT(*) >= 20
    )
),

/* ---- 입지 추천 Top 10 ---- */
site_supply AS (
    SELECT h3_r8 AS cell, ANY_VALUE(sigungu_cd) AS sigungu_cd,
           COUNT(*) AS charger_cnt,
           COUNT_IF(speed_tier IN ('급속','초급속')) AS fast_cnt,
           COUNT(DISTINCT operator_nm) AS operator_cnt
    FROM EV_ANALYTICS.ANALYSIS.V_CHARGER_ENRICHED GROUP BY 1
),
site_demand AS (
    SELECT cs.*, r.sido_nm, r.sigungu_nm,
           r.ev_cnt / NULLIF(COUNT(*) OVER (PARTITION BY cs.sigungu_cd),0) AS est_ev
    FROM site_supply cs
    LEFT JOIN EV_ANALYTICS.ANALYSIS.V_REGION r ON r.sigungu_cd = cs.sigungu_cd
),
site_util AS (
    SELECT c.h3_r8 AS cell,
           AVG(COALESCE(x.busy_min,0)/(30.0*24*60)) AS avg_util
    FROM EV_ANALYTICS.ANALYSIS.V_CHARGER_ENRICHED c
    LEFT JOIN (
        SELECT charger_key, SUM(DATEDIFF(minute, start_ts, end_ts)) AS busy_min
        FROM EV_ANALYTICS.ANALYSIS.V_SESSION
        WHERE start_ts >= DATEADD(day,-30,CURRENT_DATE()) GROUP BY 1
    ) x ON x.charger_key = c.charger_key
    GROUP BY 1
),
site_scored AS (
    SELECT d.cell, d.sido_nm, d.sigungu_nm, d.est_ev, d.charger_cnt, d.fast_cnt,
           COALESCE(u.avg_util,0) AS avg_util,
           40 * LEAST(1, (d.est_ev / NULLIF(d.charger_cnt,0)) / 50.0) AS s1,
           30 * LEAST(1, COALESCE(u.avg_util,0) / 0.35)               AS s2,
           20 * (1 - LEAST(1, d.fast_cnt / NULLIF(d.charger_cnt,0)))  AS s3,
           10 * (1.0 / NULLIF(d.operator_cnt,0))                      AS s4
    FROM site_demand d LEFT JOIN site_util u ON u.cell = d.cell
    WHERE d.est_ev >= 100
),
sites AS (
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(
        'region', sido_nm || ' ' || sigungu_nm, 'cell', cell,
        'est_ev', ROUND(est_ev,0), 'chargers', charger_cnt,
        'util', ROUND(avg_util*100,1), 'score', score)) AS a
    FROM (
        SELECT *, ROUND(s1+s2+s3+s4, 1) AS score
        FROM site_scored
        ORDER BY s1+s2+s3+s4 DESC
        LIMIT 10
    )
)

SELECT OBJECT_CONSTRUCT(
    'kpi',   (SELECT o FROM kpi),
    'cov',   (SELECT a FROM cov),
    'heat',  (SELECT a FROM heat),
    'util',  (SELECT a FROM util),
    'ops',   (SELECT a FROM ops),
    'sites', (SELECT a FROM sites)
)::VARCHAR AS DASHBOARD_JSON;
