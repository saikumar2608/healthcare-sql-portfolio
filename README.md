# Project 1 — Claims Cohort & Medication Adherence SQL Engine

## Objective
Build a diabetic patient cohort from medical and pharmacy claims data,
compute Proportion of Days Covered (PDC) for medication adherence,
analyze utilization patterns, and segment members by clinical risk.

Built to demonstrate payer analytics, quality reporting, and 
real-world evidence (RWE) analyst capabilities.

**Platform:** PostgreSQL 15 via db<>fiddle  
**Data:** Synthetic — 50 members, 30 medical claims, 71 pharmacy fills  

---

## Schema Diagram
```
member_dim (1) ──< eligibility_fact (many)
member_dim (1) ──< medical_claim_fact (many) ──< medical_claim_line_fact (many)
medical_claim_line_fact ──< medical_claim_line_dx_bridge >── diagnosis_dim
member_dim (1) ──< pharmacy_claim_fact >── drug_dim
medical_claim_fact >── provider_dim
```

---

## Key Tables Built

| Table | Purpose |
|-------|---------|
| member_dim | Patient demographics |
| eligibility_fact | Coverage spans by product line |
| medical_claim_fact | Claim headers (IP/OP/ER/PROF) |
| medical_claim_line_fact | Line-level CPT codes and charges |
| medical_claim_line_dx_bridge | Diagnosis to claim line mapping |
| pharmacy_claim_fact | Rx fills with NDC, days supply, fill date |
| drug_dim | Drug reference with antidiabetic flag |
| diagnosis_dim | ICD-10 reference with condition flags |

---

## Queries Built

| # | Query | Purpose |
|---|-------|---------|
| 1 | DX-based cohort | Members with E10/E11 diagnosis codes |
| 2 | RX-based cohort | Members with antidiabetic fills |
| 3 | Combined cohort | DX OR RX, deduplicated |
| 4 | PDC calculation | Unique covered days / eligible days per member |
| 5 | Utilization summary | ER, IP, office visits + total spend |
| 6 | Cost risk buckets | Top 5% / 5-20% / 20-50% / Bottom 50% |
| 7 | Data quality checks | 6 validation rules across all tables |
| 8 | Master summary table | Full cohort + PDC + utilization + risk flag |

---

## How to Run

1. Go to [db<>fiddle](https://dbfiddle.uk) and select **PostgreSQL 15**
2. Paste `sql/01_ddl.sql` into the left (schema) panel
3. Paste `sql/02_synthetic_data.sql` below the DDL
4. Click **Run** — all tables populate with no errors
5. Paste any query from `sql/03_analytic_queries.sql` into 
   the right panel and run

---

## Key Findings

**1. 60% of diabetic members are non-adherent (PDC < 0.80)**  
6 out of 10 members filling antidiabetic medications fell below 
the 0.80 PDC threshold used in HEDIS and CMS star ratings.
Member 1012 had a PDC of 0.082 — a single fill in an entire year —
representing a critical care gap requiring outreach.

**2. 4 members had diabetes diagnoses but zero pharmacy fills**  
Members 1011, 1013, 1018, and 1022 were identified via claims 
diagnosis codes but had no antidiabetic fills on record. 
In practice this signals uncontrolled diabetes, cash-pay fills 
at out-of-network pharmacies, or samples — all requiring 
care manager follow-up.

**3. Top 2 members drive 55% of total medical spend**  
Members 1001 ($5,530) and 1011 ($5,100) together represent 
55% of all medical spend in the diabetic cohort. 
Notably, Member 1001 is the most adherent (PDC 0.989), 
confirming their high cost is driven by disease severity 
(comorbid HTN + Heart Failure), not medication non-adherence.

---

## Clinical Context 
Proportion of Days Covered (PDC) is the CMS-preferred adherence 
metric used in Medicare Star Ratings and HEDIS reporting. 
A PDC ≥ 0.80 is the standard adherence threshold for diabetes, 
hypertension, and cholesterol medications. 

Non-adherence to antidiabetic therapy is associated with 
increased hospitalizations, ER utilization, and long-term 
complications including neuropathy, nephropathy, and retinopathy. 
The gap between Member 1012's single fill and a full year of 
coverage represents a real clinical and financial risk that 
structured outreach programs are designed to close.

---


## Data Quality Results

| Check | Result |
|-------|--------|
| Missing eligibility | ✅ PASS |
| Negative paid amounts | ✅ PASS |
| Duplicate claim IDs | ✅ PASS |
| Invalid days supply | ✅ PASS |
| Overlapping eligibility | ✅ PASS |
| Claim lines missing diagnosis | ⚠️ 7 rows — lab lines (expected pattern) |# healthcare-sql-portfolio
