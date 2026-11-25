-- =====================================================================
-- Retail Financial Health: FY2019-FY2025
-- Rebuilds the PostgreSQL analytics layer from the SEC EDGAR extract.
--
-- Run order:
--   0. Create an empty database (e.g. retail_financials) and connect to it.
--   1. Run sections 1-3, then load python/sec_annual_facts.csv into raw.sec_annual_facts
--      (pgAdmin: right-click the table > Import/Export, Header ON, comma delimiter;
--       or psql:  \copy raw.sec_annual_facts FROM 'sec_annual_facts.csv' CSV HEADER)
--   2. Run sections 4-7.
--
-- All money values are USD millions. Fiscal-year convention: see docs/data_dictionary.md.
-- NOTE: assembled from the scripts used during the project. Run it on a scratch
-- database first and compare the checks in section 7 with the dashboard.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Schemas and clean tables
-- ---------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS raw;        -- data exactly as extracted from the 10-Ks
CREATE SCHEMA IF NOT EXISTS analytics;  -- cleaned tables and ratio views

CREATE TABLE analytics.companies (
    company_id    SERIAL PRIMARY KEY,
    ticker        VARCHAR(10)  NOT NULL UNIQUE,
    company_name  VARCHAR(100) NOT NULL,
    segment       VARCHAR(50)  NOT NULL,
    fy_end_month  SMALLINT     NOT NULL CHECK (fy_end_month BETWEEN 1 AND 12)
);

INSERT INTO analytics.companies (ticker, company_name, segment, fy_end_month) VALUES
('WMT',  'Walmart',        'Big-box',                 1),
('TGT',  'Target',         'Big-box',                 1),
('COST', 'Costco',         'Big-box',                 8),
('HD',   'Home Depot',     'Home improvement',        1),
('LOW',  'Lowe''s',        'Home improvement',        1),
('KR',   'Kroger',         'Grocery',                 1),
('BBY',  'Best Buy',       'Specialty / Electronics', 1),
('DG',   'Dollar General', 'Discount / Off-price',    1),
('TJX',  'TJX Companies',  'Discount / Off-price',    1),
('M',    'Macy''s',        'Department store',        1);

CREATE TABLE analytics.income_statement (
    company_id          INT      NOT NULL REFERENCES analytics.companies(company_id),
    fiscal_year         SMALLINT NOT NULL CHECK (fiscal_year BETWEEN 2019 AND 2025),
    revenue             NUMERIC(14,2),
    cost_of_sales       NUMERIC(14,2),
    gross_profit        NUMERIC(14,2),
    operating_income    NUMERIC(14,2),
    interest_expense    NUMERIC(14,2),
    pretax_income       NUMERIC(14,2),
    income_tax          NUMERIC(14,2),
    net_income          NUMERIC(14,2),
    depreciation_amort  NUMERIC(14,2),
    interest_source     VARCHAR(20),   -- reported | reported_net | cash_paid
    notes               TEXT,          -- every derived or corrected value is logged here
    PRIMARY KEY (company_id, fiscal_year)
);

CREATE TABLE analytics.balance_sheet (
    company_id                 INT      NOT NULL REFERENCES analytics.companies(company_id),
    fiscal_year                SMALLINT NOT NULL CHECK (fiscal_year BETWEEN 2019 AND 2025),
    cash_and_equivalents       NUMERIC(14,2),
    receivables                NUMERIC(14,2),
    inventory                  NUMERIC(14,2),
    total_current_assets       NUMERIC(14,2),
    total_assets               NUMERIC(14,2),
    accounts_payable           NUMERIC(14,2),
    total_current_liabilities  NUMERIC(14,2),
    short_term_debt            NUMERIC(14,2),
    long_term_debt             NUMERIC(14,2),
    total_debt                 NUMERIC(14,2),
    operating_lease_liab       NUMERIC(14,2),   -- non-current operating lease liability only
    total_liabilities          NUMERIC(14,2),
    total_equity               NUMERIC(14,2),
    total_equity_incl_nci      NUMERIC(14,2),
    notes                      TEXT,
    debt_flag                  TEXT,            -- verification status of debt figures
    PRIMARY KEY (company_id, fiscal_year)
);

CREATE TABLE analytics.cash_flow (
    company_id            INT      NOT NULL REFERENCES analytics.companies(company_id),
    fiscal_year           SMALLINT NOT NULL CHECK (fiscal_year BETWEEN 2019 AND 2025),
    operating_cash_flow   NUMERIC(14,2),
    capital_expenditures  NUMERIC(14,2),        -- stored as a positive amount spent
    dividends_paid        NUMERIC(14,2),
    share_repurchases     NUMERIC(14,2),
    notes                 TEXT,
    PRIMARY KEY (company_id, fiscal_year)
);

-- ---------------------------------------------------------------------
-- 2. Raw landing table (load python/sec_annual_facts.csv into it)
-- ---------------------------------------------------------------------
CREATE TABLE raw.sec_annual_facts (
    ticker       VARCHAR(10),
    fiscal_year  SMALLINT,
    metric       VARCHAR(40),
    value_musd   NUMERIC(16,2),
    xbrl_tag     VARCHAR(150),
    period_end   DATE,
    filed        DATE,
    accession    VARCHAR(30)
);

-- >>> LOAD THE CSV NOW, THEN CONTINUE <<<

-- ---------------------------------------------------------------------
-- 3. Wide view: one row per company-year (a reshape only, no copying)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW raw.v_wide AS
SELECT ticker, fiscal_year,
  MAX(value_musd) FILTER (WHERE metric='revenue')                   AS revenue,
  MAX(value_musd) FILTER (WHERE metric='cost_of_sales')             AS cost_of_sales,
  MAX(value_musd) FILTER (WHERE metric='gross_profit')              AS gross_profit,
  MAX(value_musd) FILTER (WHERE metric='operating_income')          AS operating_income,
  MAX(value_musd) FILTER (WHERE metric='interest_expense')          AS interest_expense,
  MAX(value_musd) FILTER (WHERE metric='interest_paid')             AS interest_paid,
  MAX(value_musd) FILTER (WHERE metric='pretax_income')             AS pretax_income,
  MAX(value_musd) FILTER (WHERE metric='income_tax')                AS income_tax,
  MAX(value_musd) FILTER (WHERE metric='net_income')                AS net_income,
  MAX(value_musd) FILTER (WHERE metric='depreciation_amort')        AS depreciation_amort,
  MAX(value_musd) FILTER (WHERE metric='cash_and_equivalents')      AS cash_and_equivalents,
  MAX(value_musd) FILTER (WHERE metric='receivables')               AS receivables,
  MAX(value_musd) FILTER (WHERE metric='inventory')                 AS inventory,
  MAX(value_musd) FILTER (WHERE metric='inventory_fifo')            AS inventory_fifo,
  MAX(value_musd) FILTER (WHERE metric='inventory_lifo_reserve')    AS inventory_lifo_reserve,
  MAX(value_musd) FILTER (WHERE metric='total_current_assets')      AS total_current_assets,
  MAX(value_musd) FILTER (WHERE metric='total_assets')              AS total_assets,
  MAX(value_musd) FILTER (WHERE metric='accounts_payable')          AS accounts_payable,
  MAX(value_musd) FILTER (WHERE metric='total_current_liabilities') AS total_current_liabilities,
  MAX(value_musd) FILTER (WHERE metric='debt_current_a')            AS debt_current_a,
  MAX(value_musd) FILTER (WHERE metric='debt_current_b')            AS debt_current_b,
  MAX(value_musd) FILTER (WHERE metric='debt_short_borrowings')     AS debt_short_borrowings,
  MAX(xbrl_tag)   FILTER (WHERE metric='debt_short_borrowings')     AS short_tag,
  MAX(value_musd) FILTER (WHERE metric='debt_due_next_12m')         AS debt_due_next_12m,
  MAX(value_musd) FILTER (WHERE metric='debt_noncurrent_a')         AS debt_noncurrent_a,
  MAX(value_musd) FILTER (WHERE metric='debt_noncurrent_b')         AS debt_noncurrent_b,
  MAX(value_musd) FILTER (WHERE metric='debt_total_a')              AS debt_total_a,
  MAX(value_musd) FILTER (WHERE metric='debt_total_b')              AS debt_total_b,
  MAX(value_musd) FILTER (WHERE metric='operating_lease_liab')      AS operating_lease_liab,
  MAX(value_musd) FILTER (WHERE metric='total_liabilities')         AS total_liabilities,
  MAX(value_musd) FILTER (WHERE metric='total_equity')              AS total_equity,
  MAX(value_musd) FILTER (WHERE metric='total_equity_incl_nci')     AS total_equity_incl_nci,
  MAX(value_musd) FILTER (WHERE metric='operating_cash_flow')       AS operating_cash_flow,
  MAX(value_musd) FILTER (WHERE metric='capital_expenditures')      AS capital_expenditures,
  MAX(value_musd) FILTER (WHERE metric='dividends_paid')            AS dividends_paid,
  MAX(value_musd) FILTER (WHERE metric='share_repurchases')         AS share_repurchases
FROM raw.sec_annual_facts
GROUP BY ticker, fiscal_year;

-- ---------------------------------------------------------------------
-- 4. Populate the clean tables (derivations are logged in the notes columns)
-- ---------------------------------------------------------------------

-- 4a. Income statement
-- gross_profit is ALWAYS revenue - cost_of_sales so all companies use one definition
-- (Costco's reported GrossProfit tag excludes membership fees; see corrections below).
INSERT INTO analytics.income_statement
 (company_id, fiscal_year, revenue, cost_of_sales, gross_profit, operating_income,
  interest_expense, pretax_income, income_tax, net_income, depreciation_amort, interest_source, notes)
SELECT c.company_id, w.fiscal_year, w.revenue, w.cost_of_sales,
  w.revenue - w.cost_of_sales,
  COALESCE(w.operating_income, w.pretax_income + w.interest_expense),
  COALESCE(w.interest_expense, w.interest_paid),
  w.pretax_income, w.income_tax,
  COALESCE(w.net_income, w.pretax_income - w.income_tax),
  w.depreciation_amort,
  CASE WHEN w.interest_expense IS NOT NULL THEN 'reported'
       WHEN w.interest_paid    IS NOT NULL THEN 'cash_paid' END,
  NULLIF(CONCAT_WS('; ',
    CASE WHEN w.gross_profit IS NULL THEN 'gross_profit derived (revenue - cost_of_sales)' END,
    CASE WHEN w.operating_income IS NULL THEN 'operating_income derived (pretax + interest)' END,
    CASE WHEN w.net_income IS NULL THEN 'net_income derived (pretax - tax)' END), '')
FROM raw.v_wide w JOIN analytics.companies c ON c.ticker = w.ticker;

-- 4b. Balance sheet
-- Debt rule (documented in the data dictionary):
--   short-term debt = current portion of long-term debt (first available tag) + short-term borrowings;
--                     if the company reports a single "DebtCurrent" line it is used alone.
--                     Scheduled maturities from the debt note are NEVER treated as balance sheet current debt.
--   long-term debt  = non-current debt tag, else reported total debt minus short-term debt.
--   total debt      = short-term + long-term (includes finance leases; operating leases kept separate).
WITH x AS (
  SELECT w.*,
    CASE
      WHEN w.short_tag = 'DebtCurrent' THEN w.debt_short_borrowings
      WHEN COALESCE(w.debt_current_a, w.debt_current_b) IS NOT NULL
           THEN COALESCE(w.debt_current_a, w.debt_current_b) + COALESCE(w.debt_short_borrowings, 0)
      WHEN w.debt_short_borrowings IS NOT NULL THEN w.debt_short_borrowings
      ELSE 0
    END AS st_debt
  FROM raw.v_wide w
), y AS (
  SELECT x.*, COALESCE(x.debt_noncurrent_a, x.debt_noncurrent_b, x.debt_total_a - x.st_debt) AS lt_debt
  FROM x
)
INSERT INTO analytics.balance_sheet
 (company_id, fiscal_year, cash_and_equivalents, receivables, inventory, total_current_assets,
  total_assets, accounts_payable, total_current_liabilities, short_term_debt, long_term_debt,
  total_debt, operating_lease_liab, total_liabilities, total_equity, total_equity_incl_nci, notes)
SELECT c.company_id, y.fiscal_year, y.cash_and_equivalents, y.receivables,
  COALESCE(y.inventory, y.inventory_fifo - y.inventory_lifo_reserve),
  y.total_current_assets, y.total_assets, y.accounts_payable, y.total_current_liabilities,
  y.st_debt, y.lt_debt,
  CASE WHEN y.lt_debt IS NULL THEN NULL ELSE y.st_debt + y.lt_debt END,
  y.operating_lease_liab,
  COALESCE(y.total_liabilities, y.total_assets - y.total_equity_incl_nci),
  y.total_equity, y.total_equity_incl_nci,
  NULLIF(CONCAT_WS('; ',
    CASE WHEN y.inventory IS NULL THEN 'inventory derived (FIFO - LIFO reserve)' END,
    CASE WHEN y.total_liabilities IS NULL THEN 'total_liabilities derived (assets - equity incl. NCI)' END,
    CASE WHEN y.receivables IS NULL THEN 'receivables not reported separately' END,
    CASE WHEN y.lt_debt IS NULL THEN 'long-term debt missing: needs manual check' END), '')
FROM y JOIN analytics.companies c ON c.ticker = y.ticker;

-- 4c. Cash flow (a year with no reported buyback is stored as 0 and logged)
INSERT INTO analytics.cash_flow
 (company_id, fiscal_year, operating_cash_flow, capital_expenditures, dividends_paid, share_repurchases, notes)
SELECT c.company_id, w.fiscal_year, w.operating_cash_flow, w.capital_expenditures,
  w.dividends_paid, COALESCE(w.share_repurchases, 0),
  CASE WHEN w.share_repurchases IS NULL THEN 'repurchases assumed 0 (no reported value)' END
FROM raw.v_wide w JOIN analytics.companies c ON c.ticker = w.ticker;

-- ---------------------------------------------------------------------
-- 5. Manual corrections and verification flags (checked against the 10-K filings)
-- ---------------------------------------------------------------------

-- Costco: reported GrossProfit tag excludes membership fees; total revenue includes them.
-- One definition (revenue - cost_of_sales) is used for every company and year.
UPDATE analytics.income_statement i
SET notes = 'gross_profit = total revenue - cost_of_sales (revenue includes membership fees; reported GrossProfit tag excludes them)'
FROM analytics.companies c
WHERE c.company_id = i.company_id AND c.ticker = 'COST';

-- Kroger FY2024-25: the interest tag changed to a net interest line (verified vs 10-K).
-- InterestPaidNet (the fallback) is net of interest income and understated FY2024.
UPDATE analytics.income_statement i
SET interest_expense = v.val,
    interest_source  = 'reported_net',
    notes = 'gross_profit derived (revenue - cost_of_sales); interest_expense = net interest expense (InterestIncomeExpenseNonoperatingNet, absolute value); verified vs 10-K (labelled net interest expense)'
FROM (VALUES (2024, 450.00), (2025, 639.00)) AS v(fy, val)
JOIN analytics.companies c ON c.ticker = 'KR'
WHERE i.company_id = c.company_id AND i.fiscal_year = v.fy;

UPDATE analytics.income_statement i
SET notes = CONCAT_WS('; ', i.notes,
      'FY2025 operating income includes $2,497M non-cash fulfillment network impairment (verified vs 10-K)')
FROM analytics.companies c
WHERE c.company_id = i.company_id AND c.ticker = 'KR' AND i.fiscal_year = 2025;

UPDATE analytics.cash_flow f
SET notes = CONCAT_WS('; ', f.notes,
      'repurchases exclude separately reported $1,000M unsettled accelerated share repurchase; cash returned was about $1B higher')
FROM analytics.companies c
WHERE c.company_id = f.company_id AND c.ticker = 'KR' AND f.fiscal_year = 2024;

-- Debt verification flags (verified vs 10-K balance sheets)
UPDATE analytics.balance_sheet b
SET debt_flag = CASE c.ticker || b.fiscal_year
  WHEN 'M2020'   THEN 'verified vs 10-K: short-term 452 + long-term 4,407; reported LongTermDebt tag excludes short-term debt'
  WHEN 'BBY2020' THEN 'verified vs 10-K: short-term debt 110 + current portion 14 + long-term 1,253'
  WHEN 'DG2020'  THEN 'verified vs 10-K: balance sheet shows long-term obligations only, no current portion line; scheduled maturities not added'
  WHEN 'DG2021'  THEN 'verified vs 10-K: balance sheet shows long-term obligations only, no current portion line; scheduled maturities not added'
  WHEN 'DG2022'  THEN 'verified vs 10-K: balance sheet shows long-term obligations only (7,009.40), no current portion line; scheduled maturities not added'
END
FROM analytics.companies c
WHERE c.company_id = b.company_id
  AND c.ticker || b.fiscal_year IN ('M2020','BBY2020','DG2020','DG2021','DG2022');

-- ---------------------------------------------------------------------
-- 6. Ratio view (what Power BI and Excel read)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW analytics.v_ratios AS
WITH base AS (
  SELECT c.ticker, c.company_name, c.segment, i.fiscal_year,
    i.revenue, i.cost_of_sales, i.gross_profit, i.operating_income, i.interest_expense,
    i.interest_source, i.pretax_income, i.income_tax, i.net_income, i.depreciation_amort,
    b.cash_and_equivalents, b.receivables, b.inventory, b.total_current_assets, b.total_assets,
    b.accounts_payable, b.total_current_liabilities, b.total_debt, b.operating_lease_liab,
    b.total_equity, b.total_equity_incl_nci,
    f.operating_cash_flow, f.capital_expenditures, f.dividends_paid, f.share_repurchases
  FROM analytics.income_statement i
  JOIN analytics.balance_sheet b USING (company_id, fiscal_year)
  JOIN analytics.cash_flow f     USING (company_id, fiscal_year)
  JOIN analytics.companies c     USING (company_id)
)
SELECT ticker, company_name, segment, fiscal_year, revenue, net_income,

  -- Growth
  ROUND(revenue    / NULLIF(LAG(revenue)    OVER w, 0) - 1, 4) AS revenue_growth,
  ROUND(net_income / NULLIF(LAG(net_income) OVER w, 0) - 1, 4) AS net_income_growth,

  -- Profitability
  ROUND(gross_profit     / NULLIF(revenue, 0), 4)                       AS gross_margin,
  ROUND(operating_income / NULLIF(revenue, 0), 4)                       AS operating_margin,
  ROUND((operating_income + depreciation_amort) / NULLIF(revenue, 0), 4) AS ebitda_margin,
  ROUND(net_income       / NULLIF(revenue, 0), 4)                       AS net_margin,
  ROUND(net_income / NULLIF(total_assets, 0), 4)                        AS roa,
  CASE WHEN total_equity > 0 THEN ROUND(net_income / total_equity, 4) END AS roe,
  (total_equity <= 0)                                                   AS negative_equity,
  ROUND(operating_income * (1 - income_tax / NULLIF(pretax_income, 0))
        / NULLIF(total_debt + total_equity_incl_nci - cash_and_equivalents, 0), 4) AS roic,

  -- Liquidity
  ROUND(total_current_assets / NULLIF(total_current_liabilities, 0), 2)  AS current_ratio,
  ROUND((cash_and_equivalents + COALESCE(receivables, 0))
        / NULLIF(total_current_liabilities, 0), 2)                       AS quick_ratio,
  ROUND(cash_and_equivalents / NULLIF(total_current_liabilities, 0), 2)  AS cash_ratio,

  -- Leverage
  ROUND(total_debt / NULLIF(total_equity_incl_nci, 0), 2)                AS debt_to_equity,
  ROUND((total_debt + COALESCE(operating_lease_liab, 0))
        / NULLIF(total_equity_incl_nci, 0), 2)                           AS debt_to_equity_incl_leases,
  ROUND(total_debt - cash_and_equivalents, 0)                            AS net_debt,
  ROUND((total_debt - cash_and_equivalents)
        / NULLIF(operating_income + depreciation_amort, 0), 2)           AS net_debt_to_ebitda,
  ROUND((total_debt + COALESCE(operating_lease_liab, 0) - cash_and_equivalents)
        / NULLIF(operating_income + depreciation_amort, 0), 2)           AS net_debt_to_ebitda_incl_leases,
  ROUND(operating_income / NULLIF(interest_expense, 0), 2)               AS interest_coverage,
  interest_source,

  -- Working capital efficiency
  ROUND(cost_of_sales / NULLIF(inventory, 0), 2)                         AS inventory_turnover,
  ROUND(inventory         / NULLIF(cost_of_sales, 0) * 365, 1)           AS days_inventory,
  ROUND(accounts_payable  / NULLIF(cost_of_sales, 0) * 365, 1)           AS days_payable,
  ROUND((inventory - accounts_payable) / NULLIF(cost_of_sales, 0) * 365, 1) AS cash_cycle_days,

  -- Cash generation
  ROUND(operating_cash_flow - capital_expenditures, 0)                   AS free_cash_flow,
  ROUND((operating_cash_flow - capital_expenditures) / NULLIF(revenue, 0), 4) AS fcf_margin,
  ROUND(operating_cash_flow / NULLIF(net_income, 0), 2)                  AS ocf_to_net_income,
  ROUND(capital_expenditures / NULLIF(revenue, 0), 4)                    AS capex_to_revenue,
  ROUND((dividends_paid + share_repurchases)
        / NULLIF(operating_cash_flow - capital_expenditures, 0), 2)      AS payout_of_fcf,

  -- Raw cash amounts (for payout charts) and lease-adjusted ROIC
  operating_cash_flow, capital_expenditures, dividends_paid, share_repurchases,
  ROUND(operating_income * (1 - income_tax / NULLIF(pretax_income, 0))
        / NULLIF(total_debt + COALESCE(operating_lease_liab, 0)
                 + total_equity_incl_nci - cash_and_equivalents, 0), 4)  AS roic_incl_leases
FROM base
WINDOW w AS (PARTITION BY ticker ORDER BY fiscal_year);

-- ---------------------------------------------------------------------
-- 7. Checks to run after a rebuild
-- ---------------------------------------------------------------------

-- 7a. Expect 70 rows in each table and in the view (10 companies x 7 years)
SELECT (SELECT COUNT(*) FROM analytics.income_statement) AS is_rows,
       (SELECT COUNT(*) FROM analytics.balance_sheet)    AS bs_rows,
       (SELECT COUNT(*) FROM analytics.cash_flow)        AS cf_rows,
       (SELECT COUNT(*) FROM analytics.v_ratios)         AS ratio_rows;

-- 7b. Balance sheet identity where total liabilities is reported directly (expect no rows)
SELECT c.ticker, b.fiscal_year,
       ROUND(b.total_assets - b.total_liabilities - b.total_equity_incl_nci) AS gap
FROM analytics.balance_sheet b
JOIN analytics.companies c USING (company_id)
WHERE ABS(b.total_assets - b.total_liabilities - b.total_equity_incl_nci) > 1
ORDER BY c.ticker, b.fiscal_year;

-- 7c. Spot checks against the dashboard / 10-K (FY2025)
--     Kroger interest coverage: expect 2.96; Dollar General FY2022 total debt: expect 7009.40
SELECT ticker, fiscal_year, interest_coverage, net_debt_to_ebitda_incl_leases
FROM analytics.v_ratios WHERE ticker = 'KR' AND fiscal_year IN (2024, 2025);

SELECT c.ticker, b.fiscal_year, b.total_debt
FROM analytics.balance_sheet b JOIN analytics.companies c USING (company_id)
WHERE c.ticker = 'DG' AND b.fiscal_year = 2022;

-- 7d. Data quality log: every derived, corrected or flagged value
SELECT c.ticker, x.fiscal_year, x.statement, x.note
FROM (
  SELECT company_id, fiscal_year, 'income_statement' AS statement, notes AS note
  FROM analytics.income_statement WHERE notes IS NOT NULL
  UNION ALL
  SELECT company_id, fiscal_year, 'balance_sheet', CONCAT_WS('; ', notes, debt_flag)
  FROM analytics.balance_sheet WHERE notes IS NOT NULL OR debt_flag IS NOT NULL
  UNION ALL
  SELECT company_id, fiscal_year, 'cash_flow', notes
  FROM analytics.cash_flow WHERE notes IS NOT NULL
) x
JOIN analytics.companies c USING (company_id)
ORDER BY c.ticker, x.fiscal_year, x.statement;
