-- =============================================================================
-- Model Omnichannel — segmentacja klientów M1–M7 (podejście multi-tag)
-- Baza: Oracle (HALO_ANALYSE_POWERBI_PROD) · schematy POLAND / SHARED / WORK_POLAND
-- Wynik: jeden wiersz na SOLDTO_NUMBER + kolumny-tagi M1..M7 (TAK/NIE/DO_UZUPELNIENIA)
--
-- Definicje i algorytm: patrz docs/model_omnichannel_scenariusze.pdf
--
-- Kluczowe założenia:
--  * okno rolling 12 miesięcy po INVOICE_DATE
--  * sprzedaż/marża ze WSZYSTKICH linii faktur; zamówienia/sekcje/self-service
--    na poziomie zamówienia (tylko linie z ORDER_NUMBER)
--  * self-service = ORDER_CHANNEL_CODE IN ('W','X') AND T_ECOM_ACCOUNT.USER_TYPE_CODE='OLO'
--  * IS=1603, PF=1601, MM=1605 (SALES_FORCE_REGION_CODE); Corporate = SALES_FORCE_TYPE_CODE
--  * próg opłacalności = średnia AOV w regionie (tylko po klientach kwalifikujących się)
--  * MidMarket kwalifikuje się do rdzenia SMB tylko przy zatrudnieniu 0–249
--    (T_SHIPTO, wiersz self-shipto SHIPTO_NUMBER = SOLDTO_NUMBER, bez sumowania)
--
-- TODO (blokery biznesowe):
--  * M3 — kryterium "PKD sugeruje szerszy zakup" (mapa PKD -> kategorie)
--  * M5 — lista KVI + próg % udziału w koszyku
--  * M6 — źródło churn score i cykl odświeżania (T_ANTICHURN tymczasowo wyłączone)
--  * M7 — mapa PKD -> branża docelowa (przemysł ciężki, produkcja, logistyka,
--         budownictwo, HoReCa)
-- =============================================================================

WITH params AS (
    SELECT ADD_MONTHS(TRUNC(SYSDATE), -12) AS date_from FROM dual
),
-- 1) linie faktur w scope: 12m, PL, nie-anulowane/usunięte, business scope = Y
inv_lines AS (
    SELECT
        il.SOLDTO_NUMBER, il.ORDER_NUMBER, il.ORDER_DATE,
        il.ORDER_CHANNEL_CODE, il.ECOM_USER_ID,
        il.SALES_AMOUNT, il.MARGIN_AMOUNT, pr.SECTION_CODE
    FROM POLAND.T_INVOICE_LINE il
    CROSS JOIN params p
    LEFT JOIN POLAND.T_PRODUCT pr
        ON pr.PRODUCT_REFERENCE = il.PRODUCT_REFERENCE
       AND pr.COUNTRY_CODE      = il.COUNTRY_CODE
    WHERE il.COUNTRY_CODE = 'PL'
      AND il.INVOICE_DATE >= p.date_from
      AND NVL(il.CANCELLED_FLAG,'N')   <> 'Y'
      AND NVL(il.DL_DELETION_FLAG,'N') <> 'Y'
      AND il.BUSINESS_SCOPE_FLAG = 'Y'
),
-- 2) sumy per klient: sprzedaż, marża, liczba UNIKALNYCH sekcji 12m
cust_totals AS (
    SELECT
        SOLDTO_NUMBER,
        SUM(SALES_AMOUNT)            AS sales_amount_12m,
        SUM(MARGIN_AMOUNT)           AS margin_amount_12m,
        COUNT(DISTINCT SECTION_CODE) AS distinct_sections_12m
    FROM inv_lines
    GROUP BY SOLDTO_NUMBER
),
-- 3) poziom zamówienia: sekcje w zamówieniu, czy self-service (OLO w W/X)
order_level AS (
    SELECT
        il.SOLDTO_NUMBER, il.ORDER_NUMBER, il.ORDER_DATE,
        COUNT(DISTINCT il.SECTION_CODE) AS sections_in_order,
        MAX(CASE WHEN il.ORDER_CHANNEL_CODE IN ('W','X')
                  AND ea.USER_TYPE_CODE = 'OLO' THEN 1 ELSE 0 END) AS is_self_service
    FROM inv_lines il
    LEFT JOIN POLAND.T_ECOM_ACCOUNT ea ON ea.ECOM_USER_ID = il.ECOM_USER_ID
    WHERE il.ORDER_NUMBER IS NOT NULL
    GROUP BY il.SOLDTO_NUMBER, il.ORDER_NUMBER, il.ORDER_DATE
),
cust_orders AS (
    SELECT
        SOLDTO_NUMBER,
        COUNT(*)                                    AS orders_12m,
        AVG(sections_in_order)                      AS avg_sections_per_order,
        SUM(is_self_service)*1.0/NULLIF(COUNT(*),0) AS pct_self_service
    FROM order_level
    GROUP BY SOLDTO_NUMBER
),
customer_12m AS (
    SELECT
        t.SOLDTO_NUMBER, t.sales_amount_12m, t.margin_amount_12m, t.distinct_sections_12m,
        o.orders_12m,
        t.sales_amount_12m/NULLIF(o.orders_12m,0) AS aov,
        NVL(o.avg_sections_per_order,0)           AS avg_sections_per_order,
        NVL(o.pct_self_service,0)                 AS pct_self_service
    FROM cust_totals t
    LEFT JOIN cust_orders o ON o.SOLDTO_NUMBER = t.SOLDTO_NUMBER
),
-- ZATRUDNIENIE: tylko wiersz self-shipto (SHIPTO = SOLDTO), bez sumowania
emp AS (
    SELECT
        SOLDTO_NUMBER,
        NVL(NUMBER_OF_WHITE_COLLARS,0) + NVL(NUMBER_OF_BLUE_COLLARS,0) AS employees
    FROM POLAND.T_SHIPTO
    WHERE SHIPTO_NUMBER = SOLDTO_NUMBER
      AND COUNTRY_CODE  = 'PL'
      AND NVL(DL_DELETION_FLAG,'N') <> 'Y'
),
-- PKD: jeden wiersz na NIP (deduplikacja CEIDG)
pkd AS (
    SELECT NIP, PKD_KOD
    FROM (
        SELECT cg.NIP, cg.PKD_KOD,
               ROW_NUMBER() OVER (PARTITION BY cg.NIP ORDER BY cg.PKD_KOD) AS rn
        FROM WORK_POLAND.T_CEIDG_GUS cg
        WHERE NVL(cg.DELETION_FLAG,'N') <> 'Y'
    )
    WHERE rn = 1
),
-- baza: segment/region + zatrudnienie + kwalifikacja do rdzenia SMB
base AS (
    SELECT
        c.*,
        ts.SOLDTO_NAME,
        ts.SALES_FORCE_REGION_CODE,
        ts.SALES_FORCE_TYPE_CODE,
        ts.PAYER_NUMBER,
        e.employees,
        CASE ts.SALES_FORCE_REGION_CODE
             WHEN '1603' THEN 'IS' WHEN '1601' THEN 'PF' WHEN '1605' THEN 'MM' END AS smb_label,
        CASE
            WHEN ts.SALES_FORCE_REGION_CODE IN ('1601','1603') THEN 1              -- IS, PF: cały segment
            WHEN ts.SALES_FORCE_REGION_CODE = '1605'
                 AND NVL(e.employees,0) BETWEEN 0 AND 249 THEN 1                   -- MM: tylko 0-249
            ELSE 0
        END AS is_smb_eligible
    FROM customer_12m c
    JOIN POLAND.T_SOLDTO ts
        ON ts.SOLDTO_NUMBER = c.SOLDTO_NUMBER
       AND ts.COUNTRY_CODE  = 'PL'
       AND NVL(ts.DELETION_FLAG,'N') <> 'Y'
    LEFT JOIN emp e ON e.SOLDTO_NUMBER = c.SOLDTO_NUMBER
),
-- próg = średnia AOV w regionie, liczona TYLKO po kwalifikujących się klientach
enriched AS (
    SELECT
        b.*,
        pk.PKD_KOD,
        AVG(CASE WHEN b.is_smb_eligible = 1 THEN b.aov END)
            OVER (PARTITION BY b.SALES_FORCE_REGION_CODE) AS region_avg_aov
    FROM base b
    LEFT JOIN POLAND.T_PAYER tp
        ON tp.PAYER_NUMBER = b.PAYER_NUMBER AND tp.COUNTRY_CODE = 'PL'
    LEFT JOIN pkd pk
        ON pk.NIP = REGEXP_REPLACE(tp.TAX_NUMBER1, '[^0-9]', '')
)
SELECT
    SOLDTO_NUMBER, SOLDTO_NAME,
    SALES_FORCE_REGION_CODE, smb_label, SALES_FORCE_TYPE_CODE,
    employees,
    ROUND(sales_amount_12m,2)  AS sales_amount_12m,
    ROUND(margin_amount_12m,2) AS margin_amount_12m,
    orders_12m,
    ROUND(aov,2)               AS aov,
    ROUND(region_avg_aov,2)    AS region_threshold_aov,
    ROUND(avg_sections_per_order,2) AS avg_sections_per_order,
    distinct_sections_12m,
    ROUND(pct_self_service,4)  AS pct_self_service,
    pkd_kod,
    CASE WHEN is_smb_eligible = 1 AND aov < region_avg_aov THEN 'TAK' ELSE 'NIE' END AS M1,
    CASE WHEN is_smb_eligible = 1 AND aov >= region_avg_aov
              AND pct_self_service BETWEEN 0.01 AND 0.9099
              AND avg_sections_per_order > 3.3 THEN 'TAK' ELSE 'NIE' END     AS M2,
    CASE WHEN is_smb_eligible = 1 AND aov >= region_avg_aov
              AND pct_self_service >= 0.91
              AND avg_sections_per_order > 3.3 THEN 'TAK' ELSE 'NIE' END     AS M2A,
    CASE WHEN is_smb_eligible = 1 AND aov >= region_avg_aov
              AND avg_sections_per_order <= 3.3 THEN 'TAK' ELSE 'NIE' END    AS M3,
    CASE WHEN SALES_FORCE_TYPE_CODE = 'CORPORATE' THEN 'TAK' ELSE 'NIE' END  AS M4,
    'DO_UZUPELNIENIA'                                                        AS M5,
    'DO_UZUPELNIENIA'                                                        AS M6,
    CASE WHEN distinct_sections_12m = 1 THEN 'DO_UZUPELNIENIA' ELSE 'NIE' END AS M7
FROM enriched
ORDER BY SOLDTO_NUMBER;
