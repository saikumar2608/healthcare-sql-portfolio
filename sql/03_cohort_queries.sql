-- ============================================================
-- PROJECT 1: Claims Cohort & Medication Adherence SQL Engine
-- Analytic Queries 1-8
-- Platform: PostgreSQL 18
-- ============================================================


-- ============================================================
-- QUERY 1: Diabetic Cohort via Diagnosis (DX-based)
-- Logic: member has E10* or E11* on any claim line in 2023
-- ============================================================
SELECT DISTINCT
    m.member_id,
    m.sex,
    m.state,
    EXTRACT(YEAR FROM AGE('2023-12-31', m.dob))  AS age_2023,
    MIN(cl.service_from_dt) OVER (PARTITION BY m.member_id) AS first_dm_claim_dt,
    'DX'                                          AS cohort_reason
FROM member_dim m
JOIN medical_claim_fact       cl  ON m.member_id  = cl.member_id
JOIN medical_claim_line_fact  ln  ON cl.claim_id  = ln.claim_id
JOIN medical_claim_line_dx_bridge dx ON ln.claim_line_id = dx.claim_line_id
JOIN diagnosis_dim             d  ON dx.icd10     = d.icd10
WHERE d.is_diabetes_flag = TRUE
  AND cl.service_from_dt BETWEEN '2023-01-01' AND '2023-12-31'
ORDER BY m.member_id;


-- ============================================================
-- QUERY 2: Diabetic Cohort via Pharmacy Fills (RX-based)
-- Logic: member has >= 1 fill for antidiabetic drug in 2023
-- ============================================================
SELECT DISTINCT
    m.member_id,
    m.sex,
    m.state,
    EXTRACT(YEAR FROM AGE('2023-12-31', m.dob)) AS age_2023,
    MIN(rx.fill_dt) OVER (PARTITION BY m.member_id) AS first_rx_fill_dt,
    'RX'                                         AS cohort_reason
FROM member_dim m
JOIN pharmacy_claim_fact rx ON m.member_id = rx.member_id
JOIN drug_dim             d  ON rx.ndc      = d.ndc
WHERE d.is_antidiabetic_flag = TRUE
  AND rx.fill_dt BETWEEN '2023-01-01' AND '2023-12-31'
ORDER BY m.member_id;


-- ============================================================
-- QUERY 3: Final Diabetic Cohort (DX OR RX)
-- Member qualifies if they have EITHER a DM diagnosis
-- OR an antidiabetic fill — deduplicated with DX taking priority
-- ============================================================
WITH dx_cohort AS (
    SELECT DISTINCT
        m.member_id,
        MIN(cl.service_from_dt) AS index_dt,
        'DX'                    AS cohort_reason
    FROM member_dim m
    JOIN medical_claim_fact       cl ON m.member_id    = cl.member_id
    JOIN medical_claim_line_fact  ln ON cl.claim_id    = ln.claim_id
    JOIN medical_claim_line_dx_bridge dx ON ln.claim_line_id = dx.claim_line_id
    JOIN diagnosis_dim             d  ON dx.icd10      = d.icd10
    WHERE d.is_diabetes_flag = TRUE
      AND cl.service_from_dt BETWEEN '2023-01-01' AND '2023-12-31'
    GROUP BY m.member_id
),
rx_cohort AS (
    SELECT DISTINCT
        m.member_id,
        MIN(rx.fill_dt) AS index_dt,
        'RX'            AS cohort_reason
    FROM member_dim m
    JOIN pharmacy_claim_fact rx ON m.member_id = rx.member_id
    JOIN drug_dim              d ON rx.ndc      = d.ndc
    WHERE d.is_antidiabetic_flag = TRUE
      AND rx.fill_dt BETWEEN '2023-01-01' AND '2023-12-31'
    GROUP BY m.member_id
),
combined AS (
    SELECT * FROM dx_cohort
    UNION
    SELECT * FROM rx_cohort
)
SELECT DISTINCT ON (member_id)
    member_id,
    index_dt,
    cohort_reason,
    2023 AS measurement_year
FROM combined
ORDER BY member_id, cohort_reason;


-- ============================================================
-- QUERY 4: PDC — Proportion of Days Covered
-- Method: expand each fill to individual days, count UNIQUE
--         covered days within measurement year,
--         divide by eligible enrollment days
-- PDC >= 0.80 = ADHERENT (CMS Star Rating threshold)
-- ============================================================
WITH fills AS (
    SELECT
        rx.member_id,
        d.therapeutic_class,
        rx.fill_dt                                          AS fill_start,
        LEAST(
            rx.fill_dt + rx.days_supply - 1,
            DATE '2023-12-31'
        )                                                   AS fill_end
    FROM pharmacy_claim_fact rx
    JOIN drug_dim d ON rx.ndc = d.ndc
    WHERE d.is_antidiabetic_flag = TRUE
      AND rx.fill_dt BETWEEN '2023-01-01' AND '2023-12-31'
),
date_series AS (
    SELECT DISTINCT
        member_id,
        therapeutic_class,
        generate_series(fill_start, fill_end, INTERVAL '1 day')::DATE AS covered_day
    FROM fills
),
covered AS (
    SELECT
        member_id,
        therapeutic_class,
        COUNT(DISTINCT covered_day) AS covered_days
    FROM date_series
    GROUP BY member_id, therapeutic_class
),
eligible AS (
    SELECT
        member_id,
        SUM(
            LEAST(cov_end_dt, DATE '2023-12-31')
            - GREATEST(cov_start_dt, DATE '2023-01-01')
            + 1
        ) AS eligible_days
    FROM eligibility_fact
    WHERE cov_start_dt <= '2023-12-31'
      AND cov_end_dt   >= '2023-01-01'
    GROUP BY member_id
)
SELECT
    c.member_id,
    c.therapeutic_class,
    2023                                                        AS measurement_year,
    c.covered_days,
    e.eligible_days,
    ROUND(c.covered_days::NUMERIC / e.eligible_days, 3)        AS pdc,
    CASE
        WHEN ROUND(c.covered_days::NUMERIC / e.eligible_days, 3) >= 0.80
        THEN 'ADHERENT'
        ELSE 'NON-ADHERENT'
    END                                                         AS adherence_status
FROM covered c
JOIN eligible e ON c.member_id = e.member_id
ORDER BY c.member_id, c.therapeutic_class;


-- ============================================================
-- QUERY 5: Utilization Summary per Diabetic Member
-- Counts ER visits, IP admissions, office visits
-- and total medical spend for 2023
-- ============================================================
WITH diabetic_members AS (
    SELECT DISTINCT m.member_id
    FROM member_dim m
    JOIN medical_claim_fact       cl ON m.member_id    = cl.member_id
    JOIN medical_claim_line_fact  ln ON cl.claim_id    = ln.claim_id
    JOIN medical_claim_line_dx_bridge dx ON ln.claim_line_id = dx.claim_line_id
    JOIN diagnosis_dim             d  ON dx.icd10      = d.icd10
    WHERE d.is_diabetes_flag = TRUE
    UNION
    SELECT DISTINCT rx.member_id
    FROM pharmacy_claim_fact rx
    JOIN drug_dim d ON rx.ndc = d.ndc
    WHERE d.is_antidiabetic_flag = TRUE
)
SELECT
    cl.member_id,
    2023                                                    AS measurement_year,
    COUNT(CASE WHEN cl.claim_type = 'ER'   THEN 1 END)     AS er_visits,
    COUNT(CASE WHEN cl.claim_type = 'IP'   THEN 1 END)     AS ip_admits,
    COUNT(CASE WHEN cl.claim_type = 'PROF' THEN 1 END)     AS office_visits,
    SUM(cl.paid_amt)                                        AS total_paid_amt,
    ROUND(AVG(cl.paid_amt), 2)                              AS avg_paid_per_claim
FROM medical_claim_fact cl
WHERE cl.member_id IN (SELECT member_id FROM diabetic_members)
  AND cl.service_from_dt BETWEEN '2023-01-01' AND '2023-12-31'
GROUP BY cl.member_id
ORDER BY total_paid_amt DESC;


-- ============================================================
-- QUERY 6: Cost Risk Buckets
-- Segments diabetic members into cost tiers
-- Top 5% | 5-20% | 20-50% | Bottom 50%
-- Used for population health targeting and care management
-- ============================================================
WITH diabetic_members AS (
    SELECT DISTINCT m.member_id
    FROM member_dim m
    JOIN medical_claim_fact       cl ON m.member_id    = cl.member_id
    JOIN medical_claim_line_fact  ln ON cl.claim_id    = ln.claim_id
    JOIN medical_claim_line_dx_bridge dx ON ln.claim_line_id = dx.claim_line_id
    JOIN diagnosis_dim             d  ON dx.icd10      = d.icd10
    WHERE d.is_diabetes_flag = TRUE
    UNION
    SELECT DISTINCT rx.member_id
    FROM pharmacy_claim_fact rx
    JOIN drug_dim d ON rx.ndc = d.ndc
    WHERE d.is_antidiabetic_flag = TRUE
),
member_costs AS (
    SELECT
        cl.member_id,
        SUM(cl.paid_amt) AS total_paid_amt
    FROM medical_claim_fact cl
    WHERE cl.member_id IN (SELECT member_id FROM diabetic_members)
      AND cl.service_from_dt BETWEEN '2023-01-01' AND '2023-12-31'
    GROUP BY cl.member_id
),
ranked AS (
    SELECT
        member_id,
        total_paid_amt,
        PERCENT_RANK() OVER (ORDER BY total_paid_amt DESC) AS cost_percentile
    FROM member_costs
)
SELECT
    member_id,
    2023                                                     AS measurement_year,
    total_paid_amt,
    ROUND(CAST(cost_percentile * 100 AS NUMERIC), 1)         AS percentile,
    CASE
        WHEN cost_percentile <= 0.05                              THEN 'Top 5%'
        WHEN cost_percentile > 0.05  AND cost_percentile <= 0.20 THEN '5-20%'
        WHEN cost_percentile > 0.20  AND cost_percentile <= 0.50 THEN '20-50%'
        ELSE                                                          'Bottom 50%'
    END AS cost_bucket
FROM ranked
ORDER BY total_paid_amt DESC;


-- ============================================================
-- QUERY 7: Data Quality Validation Checks
-- Run these before trusting ANY downstream analysis
-- ============================================================

-- CHECK 1: Members with claims but no matching eligibility window
SELECT
    'Missing Eligibility' AS check_name,
    cl.member_id,
    cl.service_from_dt,
    cl.claim_type
FROM medical_claim_fact cl
WHERE NOT EXISTS (
    SELECT 1 FROM eligibility_fact e
    WHERE e.member_id = cl.member_id
      AND cl.service_from_dt BETWEEN e.cov_start_dt AND e.cov_end_dt
)
ORDER BY cl.member_id;

-- CHECK 2: Claims where service date is outside eligibility window
SELECT
    'Service Outside Eligibility' AS check_name,
    cl.member_id,
    cl.service_from_dt,
    e.cov_start_dt,
    e.cov_end_dt,
    cl.paid_amt
FROM medical_claim_fact cl
LEFT JOIN eligibility_fact e ON cl.member_id = e.member_id
WHERE cl.service_from_dt < e.cov_start_dt
   OR cl.service_from_dt > e.cov_end_dt
ORDER BY cl.member_id;

-- CHECK 3: Negative or zero paid amounts
SELECT
    'Negative or Zero Paid Amount' AS check_name,
    claim_id,
    member_id,
    service_from_dt,
    paid_amt,
    claim_type
FROM medical_claim_fact
WHERE paid_amt <= 0
ORDER BY paid_amt;

-- CHECK 4: Duplicate claim IDs (should return 0 rows)
SELECT
    'Duplicate Claim ID' AS check_name,
    claim_id,
    COUNT(*) AS occurrences
FROM medical_claim_fact
GROUP BY claim_id
HAVING COUNT(*) > 1;

-- CHECK 5: Pharmacy fills with zero or null days supply
SELECT
    'Invalid Days Supply' AS check_name,
    rx_claim_id,
    member_id,
    fill_dt,
    days_supply,
    ndc
FROM pharmacy_claim_fact
WHERE days_supply <= 0
   OR days_supply IS NULL;

-- CHECK 6: Overlapping eligibility spans per member
SELECT
    'Overlapping Eligibility' AS check_name,
    a.member_id,
    a.cov_start_dt  AS span1_start,
    a.cov_end_dt    AS span1_end,
    b.cov_start_dt  AS span2_start,
    b.cov_end_dt    AS span2_end
FROM eligibility_fact a
JOIN eligibility_fact b
    ON  a.member_id      = b.member_id
    AND a.eligibility_id < b.eligibility_id
    AND a.cov_end_dt    >= b.cov_start_dt
ORDER BY a.member_id;

-- CHECK 7: Claim lines with no diagnosis attached
SELECT
    'Claim Line Missing Diagnosis' AS check_name,
    ln.claim_line_id,
    ln.claim_id,
    cl.member_id,
    cl.service_from_dt,
    ln.cpt_hcpcs
FROM medical_claim_line_fact ln
JOIN medical_claim_fact cl ON ln.claim_id = cl.claim_id
WHERE NOT EXISTS (
    SELECT 1 FROM medical_claim_line_dx_bridge dx
    WHERE dx.claim_line_id = ln.claim_line_id
)
ORDER BY cl.member_id;

-- CHECK 8: DQ Dashboard Summary — 
SELECT
    check_name,
    failed_count,
    CASE WHEN failed_count = 0 THEN 'PASS' ELSE 'FAIL' END AS status
FROM (
    SELECT 'Missing Eligibility' AS check_name,
        COUNT(*) AS failed_count
    FROM medical_claim_fact cl
    WHERE NOT EXISTS (
        SELECT 1 FROM eligibility_fact e
        WHERE e.member_id = cl.member_id
          AND cl.service_from_dt BETWEEN e.cov_start_dt AND e.cov_end_dt
    )
    UNION ALL
    SELECT 'Negative Paid Amount',
        COUNT(*)
    FROM medical_claim_fact
    WHERE paid_amt <= 0
    UNION ALL
    SELECT 'Duplicate Claim IDs',
        COUNT(*) FROM (
            SELECT claim_id FROM medical_claim_fact
            GROUP BY claim_id HAVING COUNT(*) > 1
        ) x
    UNION ALL
    SELECT 'Invalid Days Supply',
        COUNT(*)
    FROM pharmacy_claim_fact
    WHERE days_supply <= 0 OR days_supply IS NULL
    UNION ALL
    SELECT 'Overlapping Eligibility',
        COUNT(*) FROM (
            SELECT a.member_id
            FROM eligibility_fact a
            JOIN eligibility_fact b
                ON  a.member_id = b.member_id
                AND a.eligibility_id < b.eligibility_id
                AND a.cov_end_dt >= b.cov_start_dt
        ) x
    UNION ALL
    SELECT 'Claim Lines Missing Dx',
        COUNT(*)
    FROM medical_claim_line_fact ln
    WHERE NOT EXISTS (
        SELECT 1 FROM medical_claim_line_dx_bridge dx
        WHERE dx.claim_line_id = ln.claim_line_id
    )
) dq_summary
ORDER BY failed_count DESC;


-- ============================================================
-- QUERY 8: Master Summary Table
-- Full cohort + PDC + utilization + cost bucket + risk flag

-- ============================================================
WITH diabetic_cohort AS (
    WITH dx_cohort AS (
        SELECT DISTINCT m.member_id,
            MIN(cl.service_from_dt) AS index_dt,
            'DX' AS cohort_reason
        FROM member_dim m
        JOIN medical_claim_fact       cl ON m.member_id    = cl.member_id
        JOIN medical_claim_line_fact  ln ON cl.claim_id    = ln.claim_id
        JOIN medical_claim_line_dx_bridge dx ON ln.claim_line_id = dx.claim_line_id
        JOIN diagnosis_dim             d  ON dx.icd10      = d.icd10
        WHERE d.is_diabetes_flag = TRUE
          AND cl.service_from_dt BETWEEN '2023-01-01' AND '2023-12-31'
        GROUP BY m.member_id
    ),
    rx_cohort AS (
        SELECT DISTINCT m.member_id,
            MIN(rx.fill_dt) AS index_dt,
            'RX' AS cohort_reason
        FROM member_dim m
        JOIN pharmacy_claim_fact rx ON m.member_id = rx.member_id
        JOIN drug_dim              d ON rx.ndc      = d.ndc
        WHERE d.is_antidiabetic_flag = TRUE
          AND rx.fill_dt BETWEEN '2023-01-01' AND '2023-12-31'
        GROUP BY m.member_id
    ),
    combined AS (
        SELECT * FROM dx_cohort
        UNION
        SELECT * FROM rx_cohort
    )
    SELECT DISTINCT ON (member_id)
        member_id, index_dt, cohort_reason
    FROM combined
    ORDER BY member_id, cohort_reason
),
pdc_summary AS (
    WITH fills AS (
        SELECT
            rx.member_id,
            rx.fill_dt AS fill_start,
            LEAST(rx.fill_dt + rx.days_supply - 1, DATE '2023-12-31') AS fill_end
        FROM pharmacy_claim_fact rx
        JOIN drug_dim d ON rx.ndc = d.ndc
        WHERE d.is_antidiabetic_flag = TRUE
          AND rx.fill_dt BETWEEN '2023-01-01' AND '2023-12-31'
    ),
    date_series AS (
        SELECT DISTINCT
            member_id,
            generate_series(fill_start, fill_end, INTERVAL '1 day')::DATE AS covered_day
        FROM fills
    ),
    covered AS (
        SELECT member_id, COUNT(DISTINCT covered_day) AS covered_days
        FROM date_series
        GROUP BY member_id
    ),
    eligible AS (
        SELECT member_id,
            SUM(
                LEAST(cov_end_dt, DATE '2023-12-31')
                - GREATEST(cov_start_dt, DATE '2023-01-01') + 1
            ) AS eligible_days
        FROM eligibility_fact
        WHERE cov_start_dt <= '2023-12-31' AND cov_end_dt >= '2023-01-01'
        GROUP BY member_id
    )
    SELECT
        c.member_id,
        c.covered_days,
        e.eligible_days,
        ROUND(c.covered_days::NUMERIC / e.eligible_days, 3) AS pdc,
        CASE
            WHEN ROUND(c.covered_days::NUMERIC / e.eligible_days, 3) >= 0.80
            THEN 'ADHERENT'
            ELSE 'NON-ADHERENT'
        END AS adherence_status
    FROM covered c
    JOIN eligible e ON c.member_id = e.member_id
),
utilization AS (
    SELECT
        member_id,
        COUNT(CASE WHEN claim_type = 'ER'   THEN 1 END) AS er_visits,
        COUNT(CASE WHEN claim_type = 'IP'   THEN 1 END) AS ip_admits,
        COUNT(CASE WHEN claim_type = 'PROF' THEN 1 END) AS office_visits,
        SUM(paid_amt)                                   AS total_paid_amt
    FROM medical_claim_fact
    WHERE service_from_dt BETWEEN '2023-01-01' AND '2023-12-31'
    GROUP BY member_id
),
cost_buckets AS (
    SELECT
        member_id,
        total_paid_amt,
        CASE
            WHEN PERCENT_RANK() OVER (ORDER BY total_paid_amt DESC) <= 0.05
                THEN 'Top 5%'
            WHEN PERCENT_RANK() OVER (ORDER BY total_paid_amt DESC) <= 0.20
                THEN '5-20%'
            WHEN PERCENT_RANK() OVER (ORDER BY total_paid_amt DESC) <= 0.50
                THEN '20-50%'
            ELSE 'Bottom 50%'
        END AS cost_bucket
    FROM utilization
)
SELECT
    m.member_id,
    m.sex,
    m.state,
    EXTRACT(YEAR FROM AGE('2023-12-31', m.dob))::INT   AS age_2023,
    e.product_line,
    dc.cohort_reason,
    dc.index_dt,
    2023                                                AS measurement_year,
    COALESCE(p.covered_days, 0)                         AS covered_days,
    COALESCE(p.eligible_days, 365)                      AS eligible_days,
    COALESCE(p.pdc, 0)                                  AS pdc,
    COALESCE(p.adherence_status, 'NO RX DATA')          AS adherence_status,
    COALESCE(u.er_visits, 0)                            AS er_visits,
    COALESCE(u.ip_admits, 0)                            AS ip_admits,
    COALESCE(u.office_visits, 0)                        AS office_visits,
    COALESCE(u.total_paid_amt, 0)                       AS total_paid_amt,
    COALESCE(cb.cost_bucket, 'No Claims')               AS cost_bucket,
    CASE
        WHEN COALESCE(p.pdc, 0) < 0.80
         AND COALESCE(cb.cost_bucket,'') IN ('Top 5%','5-20%')
        THEN 'HIGH RISK — Intervene Now'
        WHEN COALESCE(p.pdc, 0) < 0.80
        THEN 'MODERATE RISK — Adherence Gap'
        WHEN COALESCE(cb.cost_bucket,'') IN ('Top 5%','5-20%')
        THEN 'HIGH COST — Review Utilization'
        ELSE 'STABLE'
    END                                                 AS clinical_risk_flag
FROM diabetic_cohort dc
JOIN member_dim       m  ON dc.member_id = m.member_id
JOIN eligibility_fact e  ON dc.member_id = e.member_id
LEFT JOIN pdc_summary p  ON dc.member_id = p.member_id
LEFT JOIN utilization u  ON dc.member_id = u.member_id
LEFT JOIN cost_buckets cb ON dc.member_id = cb.member_id
ORDER BY total_paid_amt DESC, pdc ASC;
```

---

## Your GitHub File Structure Should Be
```
healthcare-sql-portfolio/
│
├── README.md
├── sql/
│   ├── 01_ddl.sql
│   ├── 02_synthetic_data.sql
│   └── 03_analytic_queries.sql   ← this file
└── outputs/
    ├── master_summary.csv
    └── dq_dashboard.csv
