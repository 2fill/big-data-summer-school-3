/* ============================================================================
   [선택] 데모 데이터 생성 — 실제 원본 테이블이 아직 없을 때
   이 스크립트를 먼저 실행하면 ev_charging_analysis.sql 의 0번 블록을
   수정하지 않고 그대로 전체 분석을 돌려볼 수 있습니다.
   Snowflake 워크시트에 통째로 붙여넣고 "Run All" 하세요. (약 10~20초)
   ============================================================================ */

CREATE DATABASE IF NOT EXISTS EV_ANALYTICS;
CREATE SCHEMA   IF NOT EXISTS EV_ANALYTICS.RAW_EV;
CREATE SCHEMA   IF NOT EXISTS EV_ANALYTICS.REF_GEO;
CREATE SCHEMA   IF NOT EXISTS EV_ANALYTICS.ANALYSIS;

USE DATABASE EV_ANALYTICS;

/* ---------------------------------------------------------------------------
   1) 시군구 기준 정보 — 실제 인구/전기차 등록대수 규모를 반영한 20개 지역
   --------------------------------------------------------------------------- */
CREATE OR REPLACE TABLE EV_ANALYTICS.REF_GEO.REGION_STATS (
    SIGUNGU_CD VARCHAR, SIDO_NM VARCHAR, SIGUNGU_NM VARCHAR,
    POPULATION NUMBER, EV_REGISTERED NUMBER, AREA_KM2 FLOAT,
    C_LAT FLOAT, C_LNG FLOAT
);

INSERT INTO EV_ANALYTICS.REF_GEO.REGION_STATS VALUES
 ('11680','서울','강남구',  539000, 11800,  39.5, 37.4959, 127.0664),
 ('11650','서울','서초구',  413000,  9600,  47.0, 37.4837, 127.0324),
 ('11710','서울','송파구',  655000, 10200,  33.9, 37.5145, 127.1060),
 ('11440','서울','마포구',  366000,  5100,  23.8, 37.5638, 126.9084),
 ('11305','서울','강북구',  292000,  2400,  23.6, 37.6396, 127.0257),
 ('41135','경기','성남시분당구', 484000, 12400, 69.4, 37.3826, 127.1189),
 ('41465','경기','용인시수지구', 380000,  8900, 42.1, 37.3220, 127.0977),
 ('41285','경기','고양시일산동구',290000, 5600, 60.0, 37.6584, 126.7770),
 ('41111','경기','수원시장안구', 285000, 4700, 33.2, 37.3049, 126.9977),
 ('41190','경기','부천시',   790000,  9100,  53.4, 37.5035, 126.7660),
 ('41250','경기','동두천시',  90000,   620,  95.7, 37.9036, 127.0606),
 ('41800','경기','연천군',    41000,   210, 696.2, 38.0965, 127.0748),
 ('28185','인천','연수구',   390000,  7300,  55.3, 37.4103, 126.6784),
 ('26350','부산','해운대구', 380000,  4200,  51.5, 35.1631, 129.1636),
 ('27110','대구','중구',      79000,   980,   7.1, 35.8694, 128.6062),
 ('30170','대전','유성구',   360000,  6800, 177.2, 36.3623, 127.3562),
 ('29155','광주','광산구',   400000,  5400, 222.8, 35.1396, 126.7936),
 ('43113','충북','청주시흥덕구',270000, 3900, 172.5, 36.6304, 127.4340),
 ('47170','경북','구미시',   405000,  3100, 615.4, 36.1196, 128.3446),
 ('50110','제주','제주시',   492000, 21000, 978.7, 33.4996, 126.5312);

/* ---------------------------------------------------------------------------
   2) 충전기 마스터 — 지역별 보급 격차가 나도록 가중 생성 (총 ~4,000대)
   --------------------------------------------------------------------------- */
CREATE OR REPLACE TABLE EV_ANALYTICS.RAW_EV.CHARGER_STATUS AS
WITH seq AS (
    SELECT SEQ4() AS i FROM TABLE(GENERATOR(ROWCOUNT => 4000))
),
regions AS (
    SELECT r.*, ROW_NUMBER() OVER (ORDER BY SIGUNGU_CD) - 1 AS ridx
    FROM EV_ANALYTICS.REF_GEO.REGION_STATS r
),
base AS (
    SELECT
        s.i,
        r.SIGUNGU_CD, r.SIDO_NM, r.SIGUNGU_NM, r.C_LAT, r.C_LNG, r.AREA_KM2,
        (MOD(ABS(HASH(s.i, 101)), 10000) / 10000.0) AS u
    FROM seq s
    JOIN regions r ON r.ridx = MOD(ABS(HASH(s.i)), 20)
),
weighted AS (
    SELECT * FROM base
    -- 강북구·동두천·연천·구미는 공급 부족 지역으로 표본 축소
    WHERE NOT (SIGUNGU_NM IN ('강북구','동두천시','연천군','구미시') AND u > 0.18)
)
SELECT
    'ST' || LPAD(FLOOR(ROW_NUMBER() OVER (ORDER BY i) / 2.3)::INT, 6, '0') AS STAT_ID,
    SIGUNGU_NM || ' ' ||
      DECODE(MOD(ABS(HASH(i)), 6), 0,'공영주차장', 1,'아파트', 2,'대형마트',
             3,'주민센터', 4,'휴게소', '오피스빌딩') || ' 충전소'          AS STAT_NM,
    LPAD(MOD(ABS(HASH(i, 7)), 8) + 1, 2, '0')                             AS CHGER_ID,
    SIDO_NM || ' ' || SIGUNGU_NM || ' ' || (MOD(ABS(HASH(i,3)), 400)+1) || '-' ||
      (MOD(ABS(HASH(i,4)), 30)+1)                                         AS ADDR,
    -- 시군구 중심 기준 면적에 비례해 산포
    (C_LAT + (((MOD(ABS(HASH(i, 11)), 20001) - 10000) / 10000.0) * SQRT(AREA_KM2)/180))::VARCHAR AS LAT,
    (C_LNG + (((MOD(ABS(HASH(i, 13)), 20001) - 10000) / 10000.0) * SQRT(AREA_KM2)/150))::VARCHAR AS LNG,
    LEFT(SIGUNGU_CD, 2)                                                   AS ZCODE,
    SIGUNGU_CD                                                            AS ZSCODE,
    DECODE(MOD(ABS(HASH(i, 21)), 7), 0,'환경부', 1,'차지비', 2,'에스트래픽',
           3,'GS차지비', 4,'한국전력', 5,'파워큐브', 'SK일렉링크')          AS BUSI_NM,
    DECODE(MOD(ABS(HASH(i, 21)), 7), 0,'ME', 1,'CV', 2,'ST',
           3,'GS', 4,'KP', 5,'PC', 'SK')                                  AS BUSI_ID,
    -- 완속(7kW) 다수 + 급속(50/100/200kW) 소수
    CASE WHEN MOD(ABS(HASH(i, 31)), 100) < 62 THEN 7
         WHEN MOD(ABS(HASH(i, 31)), 100) < 80 THEN 50
         WHEN MOD(ABS(HASH(i, 31)), 100) < 94 THEN 100
         ELSE 200 END::VARCHAR                                            AS OUTPUT,
    CASE WHEN MOD(ABS(HASH(i, 31)), 100) < 62 THEN '02' ELSE
         DECODE(MOD(ABS(HASH(i, 41)), 3), 0,'04', 1,'05', '08') END       AS CHGER_TYPE,
    DECODE(MOD(ABS(HASH(i, 51)), 6), 0,'A0', 1,'B0', 2,'C0',
           3,'D0', 4,'E0', 'F0')                                          AS KIND,
    IFF(MOD(ABS(HASH(i, 61)), 10) < 6, 'Y', 'N')                          AS PARKING_FREE,
    IFF(MOD(ABS(HASH(i, 71)), 10) < 2, 'Y', 'N')                          AS LIMIT_YN,
    -- 상태: 대기 62% / 충전중 24% / 통신이상 6% / 운영중지 4% / 점검 3% / 미확인 1%
    CASE WHEN MOD(ABS(HASH(i, 81)), 100) < 62 THEN '2'
         WHEN MOD(ABS(HASH(i, 81)), 100) < 86 THEN '3'
         WHEN MOD(ABS(HASH(i, 81)), 100) < 92 THEN '1'
         WHEN MOD(ABS(HASH(i, 81)), 100) < 96 THEN '4'
         WHEN MOD(ABS(HASH(i, 81)), 100) < 99 THEN '5'
         ELSE '9' END                                                     AS STAT,
    TO_VARCHAR(DATEADD(minute, -MOD(ABS(HASH(i, 91)), 4320),
                       CURRENT_TIMESTAMP()), 'YYYYMMDDHH24MISS')          AS STAT_UPD_DT,
    '24시간 이용가능'                                                      AS USE_TIME
FROM weighted;

/* ---------------------------------------------------------------------------
   3) 충전 세션 로그 — 최근 90일, 출퇴근·저녁 피크 반영 (~250K행)
   --------------------------------------------------------------------------- */
CREATE OR REPLACE TABLE EV_ANALYTICS.RAW_EV.CHARGE_SESSION AS
WITH chargers AS (
    SELECT STAT_ID, CHGER_ID, TRY_TO_NUMBER(OUTPUT) AS KW, ZSCODE,
           ROW_NUMBER() OVER (ORDER BY STAT_ID, CHGER_ID) AS rn
    FROM EV_ANALYTICS.RAW_EV.CHARGER_STATUS
    WHERE STAT IN ('2','3')                     -- 정상 충전기만 세션 발생
),
-- 충전기별 인기도: 급속일수록, 그리고 공급부족 지역일수록 세션 多
pop AS (
    SELECT c.*,
           CASE WHEN c.KW >= 100 THEN 55 WHEN c.KW >= 50 THEN 38 ELSE 14 END
           * IFF(r.EV_REGISTERED / 1000.0 > 8, 1.5, 1.0)                  AS n_sessions
    FROM chargers c
    LEFT JOIN EV_ANALYTICS.REF_GEO.REGION_STATS r ON r.SIGUNGU_CD = c.ZSCODE
),
gen AS (
    SELECT SEQ4() AS k FROM TABLE(GENERATOR(ROWCOUNT => 90))
),
expanded AS (
    SELECT p.STAT_ID, p.CHGER_ID, p.KW, g.k
    FROM pop p
    JOIN gen g ON g.k < p.n_sessions
),
timed AS (
    SELECT
        STAT_ID, CHGER_ID, KW, k,
        DATEADD(day, -MOD(ABS(HASH(STAT_ID, CHGER_ID, k)), 90), CURRENT_DATE()) AS d,
        -- 시간대 분포: 8~9시, 18~21시 피크
        CASE WHEN MOD(ABS(HASH(STAT_ID, CHGER_ID, k, 5)), 100) < 18
                  THEN 7  + MOD(ABS(HASH(k, 2)), 3)
             WHEN MOD(ABS(HASH(STAT_ID, CHGER_ID, k, 5)), 100) < 55
                  THEN 18 + MOD(ABS(HASH(k, 3)), 4)
             WHEN MOD(ABS(HASH(STAT_ID, CHGER_ID, k, 5)), 100) < 80
                  THEN 11 + MOD(ABS(HASH(k, 4)), 5)
             ELSE MOD(ABS(HASH(k, 6)), 24) END                            AS h,
        MOD(ABS(HASH(STAT_ID, k, 9)), 60)                                 AS mi,
        -- 충전 시간: 완속 3~8시간, 급속 20~50분
        IFF(KW >= 50, 20 + MOD(ABS(HASH(k, 11)), 31),
                      180 + MOD(ABS(HASH(k, 11)), 300))                   AS dur_min
    FROM expanded
)
SELECT
    'SS' || LPAD(ROW_NUMBER() OVER (ORDER BY d, h), 9, '0')               AS SESSION_ID,
    STAT_ID, CHGER_ID,
    DATEADD(minute, mi, DATEADD(hour, h, d::TIMESTAMP_NTZ))               AS START_TS,
    DATEADD(minute, mi + dur_min, DATEADD(hour, h, d::TIMESTAMP_NTZ))     AS END_TS,
    ROUND(KW * (dur_min / 60.0) * 0.82, 2)                                AS KWH,
    ROUND(KW * (dur_min / 60.0) * 0.82 * IFF(KW >= 50, 347, 292))         AS AMOUNT
FROM timed;

/* ---------------------------------------------------------------------------
   4) 확인
   --------------------------------------------------------------------------- */
SELECT 'CHARGER' AS table_nm, COUNT(*) AS row_cnt FROM EV_ANALYTICS.RAW_EV.CHARGER_STATUS
UNION ALL
SELECT 'SESSION', COUNT(*) FROM EV_ANALYTICS.RAW_EV.CHARGE_SESSION
UNION ALL
SELECT 'REGION',  COUNT(*) FROM EV_ANALYTICS.REF_GEO.REGION_STATS;

/* 이제 ev_charging_analysis.sql 을 실행하세요.
   단, 0번 블록의 FROM 절을
     RAW.EV.CHARGER_STATUS  →  EV_ANALYTICS.RAW_EV.CHARGER_STATUS
     RAW.EV.CHARGE_SESSION  →  EV_ANALYTICS.RAW_EV.CHARGE_SESSION
     REF.GEO.REGION_STATS   →  EV_ANALYTICS.REF_GEO.REGION_STATS
   로 바꿔주세요. (또는 0번 블록의 주석 처리된 데모용 버전 사용) */
