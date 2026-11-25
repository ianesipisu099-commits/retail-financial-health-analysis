# Data Dictionary

All monetary values are **USD millions**, taken from annual 10-K filings via the SEC EDGAR XBRL "company facts" API. Ratios are rounded in the SQL view (2 to 4 decimals).

## Conventions

| Topic | Rule |
|---|---|
| Fiscal year label | A fiscal year ending in **January or February** belongs to the **prior** calendar year (year ended 1 Feb 2020 = FY2019). This matches how Target, Home Depot and most Jan-year-end retailers number their years. Costco (ends late Aug / early Sep) keeps its own calendar year. |
| Period alignment | Costco's FY2019 ends ~5 months before the others' FY2019. Cross-company comparisons are by fiscal year, not by identical calendar dates. |
| Annual periods only | Flow items (income statement, cash flow) must cover 350–380 days, which includes 52/53-week years. |
| Restatements | If a figure was restated, the **most recently filed** value is used. |
| One tag per company-year | Within a metric, a company-year uses a single XBRL tag, so definitions are not mixed. |
| Missing values | Left `NULL` unless a rule below derives them. Every derived or corrected value is recorded in the `notes` column of its row. |

## Schemas

- `raw.sec_annual_facts`: one row per company, fiscal year and metric, exactly as extracted (includes the XBRL tag, period end, filing date and accession number for traceability).
- `raw.v_wide`: the same data pivoted to one row per company-year.
- `analytics.*`: cleaned tables and the ratio view used by Excel and Power BI.

## Tables

### `analytics.companies`
| Column | Meaning |
|---|---|
| company_id | Surrogate key |
| ticker | Stock ticker (unique) |
| company_name | Display name |
| segment | Big-box, Home improvement, Grocery, Specialty / Electronics, Discount / Off-price, Department store |
| fy_end_month | Month the fiscal year ends (1–12) |

### `analytics.income_statement` (key: company_id + fiscal_year)
| Column | Meaning |
|---|---|
| revenue | Total revenue (for Costco includes membership fees) |
| cost_of_sales | Cost of goods sold. **Kroger's tag excludes depreciation and amortization**, so its gross margin is not strictly comparable. |
| gross_profit | **Always `revenue - cost_of_sales`** for every company and year |
| operating_income | Reported operating income. **TJX does not report one**, so it is derived as pretax income + interest expense. |
| interest_expense | See `interest_source` |
| interest_source | `reported` (company's interest expense line), `reported_net` (net interest expense line, after interest income; Kroger FY2024–25), or `cash_paid` (cash interest paid, used only where no expense line was found: Lowe's all 7 years, Dollar General 2 years) |
| pretax_income, income_tax, net_income | As reported (net income derived as pretax − tax for one Target year) |
| depreciation_amort | Depreciation and amortization, from the cash flow statement |
| notes | Log of derivations and corrections |

### `analytics.balance_sheet` (key: company_id + fiscal_year)
| Column | Meaning |
|---|---|
| cash_and_equivalents | For Target this tag is cash, cash equivalents and short-term investments (checked against the 10-K) |
| receivables | NULL where the company does not report receivables separately (about 20 of 70 company-years; mainly Target and Dollar General) |
| inventory | As reported; Kroger derived as FIFO inventory − LIFO reserve |
| short_term_debt | Current portion of long-term debt + short-term borrowings / commercial paper (see debt rule) |
| long_term_debt | Non-current debt, including finance leases |
| total_debt | `short_term_debt + long_term_debt` |
| operating_lease_liab | **Non-current** operating lease liability only (the current portion is not included, so lease-adjusted metrics are slightly understated) |
| total_liabilities | As reported, otherwise derived as total assets − equity including non-controlling interest (40 of 70 rows) |
| total_equity, total_equity_incl_nci | Shareholders' equity without / with non-controlling interest |
| debt_flag | Verification note for debt rows checked against the 10-K |

**Debt rule.** (1) Current debt is the first available current-portion tag plus short-term borrowings, or a single "DebtCurrent" line used alone (Macy's). (2) Scheduled maturities from the debt footnote are **never** treated as balance sheet current debt (Dollar General reports only a long-term obligations line). (3) Long-term debt is the non-current tag, otherwise reported total debt minus current debt. (4) Operating leases are excluded from `total_debt` and shown separately.

### `analytics.cash_flow` (key: company_id + fiscal_year)
| Column | Meaning |
|---|---|
| operating_cash_flow | Net cash from operating activities |
| capital_expenditures | Positive amount spent (property and equipment, or "productive assets" where that is the tag the company uses) |
| dividends_paid, share_repurchases | Positive amounts paid. A year with no reported buyback is stored as 0 (3 Dollar General rows). Kroger FY2024 excludes a separately reported $1,000M unsettled accelerated share repurchase. |

## Ratio view: `analytics.v_ratios`

| Ratio | Definition |
|---|---|
| revenue_growth, net_income_growth | Year-on-year change within each company |
| gross_margin | gross_profit ÷ revenue |
| operating_margin | operating_income ÷ revenue |
| ebitda_margin | (operating_income + depreciation_amort) ÷ revenue |
| net_margin | net_income ÷ revenue |
| roa | net_income ÷ total_assets (year-end balances) |
| roe | net_income ÷ total_equity; **NULL when equity ≤ 0** (Home Depot, Lowe's in some years; flagged in `negative_equity`) |
| roic | NOPAT ÷ (total_debt + equity incl. NCI − cash), NOPAT = operating_income × (1 − income_tax ÷ pretax_income). Excludes operating leases. |
| roic_incl_leases | Same, with non-current operating lease liabilities added to invested capital |
| current_ratio | total_current_assets ÷ total_current_liabilities |
| quick_ratio | (cash + receivables) ÷ current liabilities; **cash only** where receivables are not reported (not comparable across all companies) |
| cash_ratio | cash ÷ current liabilities |
| debt_to_equity | total_debt ÷ equity incl. NCI (also shown including operating leases) |
| net_debt | total_debt − cash |
| net_debt_to_ebitda | net_debt ÷ (operating_income + depreciation_amort). Also shown including operating leases. |
| interest_coverage | operating_income ÷ interest_expense; the basis depends on `interest_source` and is **not strictly comparable across companies** |
| inventory_turnover, days_inventory, days_payable | cost_of_sales ÷ inventory; inventory ÷ cost_of_sales × 365; payables ÷ cost_of_sales × 365 |
| cash_cycle_days | days_inventory − days_payable (receivables excluded, since several retailers do not report them) |
| free_cash_flow | operating_cash_flow − capital_expenditures (no lease adjustment) |
| fcf_margin | free_cash_flow ÷ revenue |
| ocf_to_net_income | operating_cash_flow ÷ net_income (unstable when net income is near zero) |
| capex_to_revenue | capital_expenditures ÷ revenue |
| payout_of_fcf | (dividends + share repurchases) ÷ free_cash_flow |

## Power BI aggregation rules

- **Net Margin** is weighted: total net income ÷ total revenue across the selected companies.
- Other ratios (gross and operating margin, current ratio, leverage, ROIC) are **simple averages** across the selected companies.
- Leverage measures **exclude company-years with EBITDA ≤ 0** (Macy's FY2020), where the ratio is not meaningful.
- **Cash Conversion** is operating cash flow ÷ EBITDA, excluding EBITDA ≤ 0 years. Operating cash flow ÷ net income is kept separately because it explodes when net income is near zero.
- Conditional formatting thresholds are rules of thumb, not standards: net debt/EBITDA above 2.5 red and above 1.5 amber; current ratio below 1.0 red.
