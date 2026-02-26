-- ============================================================
-- PROJECT 1: Claims Cohort & Medication Adherence SQL Engine
-- DDL Script | PostgreSQL 18
-- ============================================================

-- ────────────────────────────────
-- 1. MEMBER_DIM
-- ────────────────────────────────
CREATE TABLE member_dim (
    member_id       BIGINT PRIMARY KEY,
    dob             DATE,
    sex             CHAR(1),
    zip3            CHAR(3),
    state           CHAR(2),
    death_dt        DATE,
    source_system   VARCHAR(50)
);

-- ────────────────────────────────
-- 2. ELIGIBILITY_FACT
-- ────────────────────────────────
CREATE TABLE eligibility_fact (
    eligibility_id  BIGINT PRIMARY KEY,
    member_id       BIGINT REFERENCES member_dim(member_id),
    cov_start_dt    DATE NOT NULL,
    cov_end_dt      DATE NOT NULL,
    product_line    VARCHAR(30),
    plan_type       VARCHAR(10),
    load_batch_id   INT,
    load_dt         TIMESTAMP DEFAULT NOW()
);

-- ────────────────────────────────
-- 3. PROVIDER_DIM
-- ────────────────────────────────
CREATE TABLE provider_dim (
    provider_id     BIGINT PRIMARY KEY,
    npi             CHAR(10),
    provider_name   VARCHAR(100),
    specialty       VARCHAR(100),
    state           CHAR(2)
);

-- ────────────────────────────────
-- 4. DIAGNOSIS_DIM
-- ────────────────────────────────
CREATE TABLE diagnosis_dim (
    icd10               VARCHAR(10) PRIMARY KEY,
    dx_desc             VARCHAR(200),
    is_diabetes_flag    BOOLEAN DEFAULT FALSE,
    is_htn_flag         BOOLEAN DEFAULT FALSE,
    is_hf_flag          BOOLEAN DEFAULT FALSE
);

-- ────────────────────────────────
-- 5. PROCEDURE_DIM
-- ────────────────────────────────
CREATE TABLE procedure_dim (
    cpt_hcpcs       VARCHAR(10) PRIMARY KEY,
    proc_desc       VARCHAR(200),
    proc_category   VARCHAR(50)
);

-- ────────────────────────────────
-- 6. DRUG_DIM
-- ────────────────────────────────
CREATE TABLE drug_dim (
    ndc                     CHAR(11) PRIMARY KEY,
    generic_name            VARCHAR(100),
    brand_name              VARCHAR(100),
    gpi                     VARCHAR(20),
    therapeutic_class       VARCHAR(50),
    is_antidiabetic_flag    BOOLEAN DEFAULT FALSE
);

-- ────────────────────────────────
-- 7. MEDICAL_CLAIM_FACT
-- ────────────────────────────────
CREATE TABLE medical_claim_fact (
    claim_id            BIGINT PRIMARY KEY,
    member_id           BIGINT REFERENCES member_dim(member_id),
    provider_id         BIGINT REFERENCES provider_dim(provider_id),
    claim_type          VARCHAR(10),
    admit_dt            DATE,
    discharge_dt        DATE,
    service_from_dt     DATE,
    service_to_dt       DATE,
    paid_amt            NUMERIC(12,2),
    allowed_amt         NUMERIC(12,2),
    billed_amt          NUMERIC(12,2),
    place_of_service    CHAR(2),
    source_system       VARCHAR(50),
    load_batch_id       INT,
    load_dt             TIMESTAMP DEFAULT NOW()
);

-- ────────────────────────────────
-- 8. MEDICAL_CLAIM_LINE_FACT
-- ────────────────────────────────
CREATE TABLE medical_claim_line_fact (
    claim_line_id   BIGINT PRIMARY KEY,
    claim_id        BIGINT REFERENCES medical_claim_fact(claim_id),
    line_num        INT,
    cpt_hcpcs       VARCHAR(10) REFERENCES procedure_dim(cpt_hcpcs),
    rev_code        VARCHAR(10),
    units           NUMERIC(8,2),
    paid_amt        NUMERIC(12,2),
    allowed_amt     NUMERIC(12,2)
);

-- ────────────────────────────────
-- 9. MEDICAL_CLAIM_LINE_DX_BRIDGE
-- ────────────────────────────────
CREATE TABLE medical_claim_line_dx_bridge (
    claim_line_id   BIGINT REFERENCES medical_claim_line_fact(claim_line_id),
    dx_seq          INT,
    icd10           VARCHAR(10) REFERENCES diagnosis_dim(icd10),
    PRIMARY KEY (claim_line_id, dx_seq)
);

-- ────────────────────────────────
-- 10. PHARMACY_CLAIM_FACT
-- ────────────────────────────────
CREATE TABLE pharmacy_claim_fact (
    rx_claim_id     BIGINT PRIMARY KEY,
    member_id       BIGINT REFERENCES member_dim(member_id),
    ndc             CHAR(11) REFERENCES drug_dim(ndc),
    fill_dt         DATE NOT NULL,
    days_supply     INT,
    quantity        NUMERIC(10,3),
    paid_amt        NUMERIC(12,2),
    allowed_amt     NUMERIC(12,2),
    pharmacy_id     BIGINT,
    source_system   VARCHAR(50),
    load_batch_id   INT,
    load_dt         TIMESTAMP DEFAULT NOW()
);

-- ────────────────────────────────
-- INDEXES
-- ────────────────────────────────
CREATE INDEX idx_elig_member        ON eligibility_fact(member_id);
CREATE INDEX idx_med_claim_member   ON medical_claim_fact(member_id);
CREATE INDEX idx_med_claim_svc_dt   ON medical_claim_fact(service_from_dt);
CREATE INDEX idx_rx_member          ON pharmacy_claim_fact(member_id);
CREATE INDEX idx_rx_fill_dt         ON pharmacy_claim_fact(fill_dt);
CREATE INDEX idx_dx_bridge_line     ON medical_claim_line_dx_bridge(claim_line_id);
