"""
Pull annual financial facts for 10 US-listed retailers from the SEC EDGAR
"company facts" API and save them to sec_annual_facts.csv (USD millions).

Usage:
    pip install requests
    1. Set HEADERS below to your own name and email (the SEC blocks anonymous requests).
    2. python pull_sec.py
    3. Load sec_annual_facts.csv into raw.sec_annual_facts (see sql/01_build_database.sql).

Fiscal-year convention: a fiscal year ending in January or February belongs to the
PRIOR calendar year (e.g. year ended 1 Feb 2020 = FY2019), matching how most of the
Jan-year-end retailers number their own years. Costco (Aug/Sep year-end) keeps its
calendar year.
"""
import csv
import time
from collections import Counter
from datetime import date

import requests

HEADERS = {"User-Agent": "Your Name your.email@example.com"}
COMPANIES = ["WMT", "TGT", "COST", "HD", "LOW", "KR", "BBY", "DG", "TJX", "M"]

# metric: (type, [XBRL us-gaap tags in priority order])
METRICS = {
    "revenue": ("duration", ["Revenues", "RevenueFromContractWithCustomerExcludingAssessedTax",
                             "SalesRevenueNet", "RevenueFromContractWithCustomerIncludingAssessedTax"]),
    "cost_of_sales": ("duration", ["CostOfRevenue", "CostOfGoodsAndServicesSold", "CostOfGoodsSold",
                                   "CostOfGoodsAndServiceExcludingDepreciationDepletionAndAmortization"]),
    "gross_profit": ("duration", ["GrossProfit"]),
    "operating_income": ("duration", ["OperatingIncomeLoss"]),
    "interest_expense": ("duration", ["InterestExpense", "InterestExpenseNonoperating", "InterestExpenseDebt"]),
    "interest_paid": ("duration", ["InterestPaidNet", "InterestPaid"]),
    "pretax_income": ("duration", [
        "IncomeLossFromContinuingOperationsBeforeIncomeTaxesExtraordinaryItemsNoncontrollingInterest",
        "IncomeLossFromContinuingOperationsBeforeIncomeTaxesMinorityInterestAndIncomeLossFromEquityMethodInvestments"]),
    "income_tax": ("duration", ["IncomeTaxExpenseBenefit"]),
    "net_income": ("duration", ["NetIncomeLoss", "ProfitLoss"]),
    "depreciation_amort": ("duration", ["DepreciationDepletionAndAmortization", "DepreciationAndAmortization",
                                        "DepreciationAmortizationAndAccretionNet"]),
    "cash_and_equivalents": ("instant", ["CashAndCashEquivalentsAtCarryingValue",
                                         "CashCashEquivalentsAndShortTermInvestments"]),
    "receivables": ("instant", ["AccountsReceivableNetCurrent", "ReceivablesNetCurrent"]),
    "inventory": ("instant", ["InventoryNet"]),
    "inventory_fifo": ("instant", ["FIFOInventoryAmount"]),
    "inventory_lifo_reserve": ("instant", ["InventoryLIFOReserve"]),
    "total_current_assets": ("instant", ["AssetsCurrent"]),
    "total_assets": ("instant", ["Assets"]),
    "accounts_payable": ("instant", ["AccountsPayableCurrent", "AccountsPayableTradeCurrent"]),
    "total_current_liabilities": ("instant", ["LiabilitiesCurrent"]),
    # Debt is pulled as separate candidate lines and resolved in SQL (see data dictionary).
    "debt_current_a": ("instant", ["LongTermDebtCurrent"]),
    "debt_current_b": ("instant", ["LongTermDebtAndCapitalLeaseObligationsCurrent"]),
    "debt_short_borrowings": ("instant", ["ShortTermBorrowings", "CommercialPaper", "DebtCurrent"]),
    "debt_due_next_12m": ("instant", ["LongTermDebtMaturitiesRepaymentsOfPrincipalInNextTwelveMonths"]),
    "debt_noncurrent_a": ("instant", ["LongTermDebtNoncurrent"]),
    "debt_noncurrent_b": ("instant", ["LongTermDebtAndCapitalLeaseObligations"]),
    "debt_total_a": ("instant", ["LongTermDebt"]),
    "debt_total_b": ("instant", ["LongTermDebtAndCapitalLeaseObligationsIncludingCurrentMaturities"]),
    "operating_lease_liab": ("instant", ["OperatingLeaseLiabilityNoncurrent", "OperatingLeaseLiability"]),
    "total_liabilities": ("instant", ["Liabilities"]),
    "total_equity": ("instant", ["StockholdersEquity",
                                 "StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest"]),
    "total_equity_incl_nci": ("instant", ["StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest",
                                          "StockholdersEquity"]),
    "operating_cash_flow": ("duration", ["NetCashProvidedByUsedInOperatingActivities"]),
    "capital_expenditures": ("duration", ["PaymentsToAcquirePropertyPlantAndEquipment",
                                          "PaymentsToAcquireProductiveAssets"]),
    "dividends_paid": ("duration", ["PaymentsOfDividends", "PaymentsOfDividendsCommonStock"]),
    "share_repurchases": ("duration", ["PaymentsForRepurchaseOfCommonStock"]),
}


def fiscal_year(end: str) -> int:
    d = date.fromisoformat(end)
    return d.year - 1 if d.month <= 2 else d.year  # Jan/Feb year-ends belong to the prior FY


def main() -> None:
    tickers = requests.get("https://www.sec.gov/files/company_tickers.json", headers=HEADERS).json()
    cik = {v["ticker"]: str(v["cik_str"]).zfill(10) for v in tickers.values()}

    rows = []
    for t in COMPANIES:
        r = requests.get(f"https://data.sec.gov/api/xbrl/companyfacts/CIK{cik[t]}.json", headers=HEADERS)
        r.raise_for_status()
        gaap = r.json()["facts"]["us-gaap"]
        time.sleep(0.3)  # stay well under the SEC rate limit
        for metric, (kind, tags) in METRICS.items():
            found = {}
            for tag in tags:  # earlier tags have priority
                for f in gaap.get(tag, {}).get("units", {}).get("USD", []):
                    if f["form"] not in ("10-K", "10-K/A"):
                        continue
                    if kind == "duration":
                        if "start" not in f:
                            continue
                        days = (date.fromisoformat(f["end"]) - date.fromisoformat(f["start"])).days
                        if not 350 <= days <= 380:  # annual periods only (covers 52/53-week years)
                            continue
                    fy = fiscal_year(f["end"])
                    if not 2019 <= fy <= 2025:
                        continue
                    if fy in found and found[fy]["tag"] != tag:
                        continue  # keep one tag per company-year; do not mix definitions
                    if fy not in found or f["filed"] > found[fy]["filed"]:  # latest filing wins (restatements)
                        found[fy] = {"tag": tag, "val": f["val"] / 1e6, "end": f["end"],
                                     "filed": f["filed"], "accn": f["accn"]}
            for fy, d in found.items():
                rows.append([t, fy, metric, round(d["val"], 2), d["tag"], d["end"], d["filed"], d["accn"]])
        print("done", t)

    with open("sec_annual_facts.csv", "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["ticker", "fiscal_year", "metric", "value_musd", "xbrl_tag", "period_end", "filed", "accession"])
        w.writerows(rows)

    # Coverage report: any metric with fewer than 7 years of data
    cnt = Counter((r[0], r[2]) for r in rows)
    print("\nGAPS (ticker, metric, years found):")
    for t in COMPANIES:
        for m in METRICS:
            if cnt[(t, m)] < 7:
                print(t, m, cnt[(t, m)])


if __name__ == "__main__":
    main()
