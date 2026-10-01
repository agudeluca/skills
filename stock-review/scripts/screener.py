"""CEDEAR + crypto screener: cheap (low P/E) and beaten-down (far from highs).

Prints markdown tables to stdout; warnings and progress go to stderr.
Data: Yahoo Finance via yfinance. Prices are the US underlying in USD, not the CEDEAR in pesos.
"""
import argparse, concurrent.futures as cf, logging, sys, warnings
from datetime import date
import pandas as pd
import yfinance as yf

warnings.filterwarnings("ignore")
logging.getLogger("yfinance").setLevel(logging.CRITICAL)

# Underlyings of CEDEARs listed on BYMA (stocks only, no ETFs). Yahoo symbols.
CEDEARS = """
AAL AAPL ABBV ABNB ABT ACN ADBE ADI ADP AEM AIG AKO-B AMAT AMD AMGN AMT AMX AMZN ANF ANGI AON ARCO
ARM ASML ASR AVGO AVY AXP AZN BA BABA BAC BAK BB BBD BBVA BCS BHP BIDU BIIB BIOX BKNG BKR BMA BMY
BP BRK-B BSBR C CAAP CAH CAR CAT CCJ CCL CDE CEPU CHKP CL CMCSA COIN COP COST CRESY CRH CRM CRWD
CSCO CSX CVE CVS CVX CX DAL DD DE DECK DEO DHI DHR DIS DOCU DOW E EA EBAY EDN EFX EOG EQNR ERIC ET
ETSY F FCX FDX FMX FSLR GE GFI GGAL GGB GILD GLOB GLW GM GOLD GOOGL GPRK GRMN GS GSK HAL HBAN HCM
HD HL HMC HMY HOG HON HOOD HPE HPQ HSBC HUT IBM IBN INFY INTC IP IRS ISRG ITUB JCI JD JMIA JNJ JPM
KB KEP KGC KHC KMB KMI KO KOF LAC LAR LIN LLY LMT LOMA LOW LRCX LULU LVS LYFT LYG MA MAR MCD MCK
MDLZ MDT MELI MET META MFG MMM MO MRK MRNA MRVL MSCI MSFT MSI MSTR MU NEE NEM NFLX NGG NIO NKE NOC
NOK NOW NTES NTR NU NUE NVDA NVO NVS NXPI ON ORCL OXY PAAS PAC PAGS PAM PANW PBI PBR PCAR PDD PEP
PFE PG PGR PHG PINS PLD PLTR PM PSQH PSX PYPL QCOM RACE RBLX RGTI RIO RIOT ROKU ROST RTX SAN SAP
SBS SBUX SCCO SE SHEL SHOP SID SLB SNA SNAP SNOW SONY SPCE SPGI SPOT STLA STNE SUPV SUZ SYY T TCOM
TD TEN TEO TGS TGT TJX TM TMO TRIP TS TSLA TSM TTE TWLO TX TXN UAL UBER UBS UL UMC UNH UNP UPS
URBN USB V VALE VIST VOD VRSN VRTX VZ WBD WDC WFC WMB WMT XOM XP XPEV XYZ YELP YPF ZM
""".split()

# Top non-stablecoin cryptos. Yahoo needs a numeric suffix where the bare symbol is taken.
CRYPTOS = {
    "BTC": "BTC-USD", "ETH": "ETH-USD", "XRP": "XRP-USD", "BNB": "BNB-USD", "SOL": "SOL-USD",
    "DOGE": "DOGE-USD", "ADA": "ADA-USD", "TRX": "TRX-USD", "LINK": "LINK-USD", "AVAX": "AVAX-USD",
    "XLM": "XLM-USD", "SUI": "SUI20947-USD", "HBAR": "HBAR-USD", "BCH": "BCH-USD",
    "LTC": "LTC-USD", "DOT": "DOT-USD", "SHIB": "SHIB-USD", "UNI": "UNI7083-USD", "NEAR": "NEAR-USD",
    "APT": "APT21794-USD", "AAVE": "AAVE-USD", "ICP": "ICP-USD", "ETC": "ETC-USD", "POL": "POL28321-USD",
    "ATOM": "ATOM-USD", "FIL": "FIL-USD", "ARB": "ARB11841-USD", "OP": "OP-USD", "RENDER": "RENDER-USD",
    "INJ": "INJ-USD", "HYPE": "HYPE32196-USD", "XMR": "XMR-USD", "PEPE": "PEPE24478-USD",
    "ENA": "ENA-USD", "TAO": "TAO22974-USD", "WLD": "WLD-USD",
}


def drawdowns(close, year_rows):
    # year_rows ≈ 52 weeks of rows: 252 trading days for stocks, 365 for crypto (trades daily).
    close = close.dropna()
    px = close.iloc[-1]
    return dict(price=px, dd_ath=(px / close.max() - 1) * 100, ath_date=close.idxmax().date(),
                dd_52w=(px / close.iloc[-year_rows:].max() - 1) * 100)


def stock(t):
    for _ in range(2):  # Yahoo sometimes 404s/429s transiently
        try:
            tk = yf.Ticker(t)
            h = tk.history(period="max", auto_adjust=True)["Close"]
            if h.empty:
                continue
            i = tk.info or {}
            return dict(ticker=t, name=(i.get("shortName") or t)[:28], sector=i.get("sector"),
                        pe=i.get("trailingPE"), fpe=i.get("forwardPE"), **drawdowns(h, 252))
        except Exception:
            pass
    print(f"sin datos: {t}", file=sys.stderr)
    return None


def scan_stocks(workers):
    with cf.ThreadPoolExecutor(workers) as ex:
        rows = [r for r in ex.map(stock, CEDEARS) if r]
    df = pd.DataFrame(rows)
    df = df[(df.pe > 0) & df.pe.notna()].copy()
    # Equal-weight percentile ranks: lower P/E is better, deeper drawdown is better.
    df["score"] = (df.pe.rank(pct=True) + df.dd_ath.rank(pct=True)) / 2
    return df, len(rows)


def scan_crypto():
    d = yf.download(list(CRYPTOS.values()), period="max", progress=False, auto_adjust=True)["Close"]
    rows = []
    for sym, y in CRYPTOS.items():
        if y not in d or d[y].dropna().empty:
            print(f"sin datos: {sym}", file=sys.stderr)
            continue
        c = d[y].dropna()
        rows.append(dict(ticker=sym, since=c.index[0].year,
                         chg_30d=(c.iloc[-1] / c.iloc[-31] - 1) * 100 if len(c) > 31 else None,
                         **drawdowns(c, 365)))
    return pd.DataFrame(rows)


def pct(x):
    return "—" if pd.isna(x) else f"{x:.0f}%"


def num(x):
    return "—" if x is None or pd.isna(x) else f"{x:.1f}"


def money(x):
    return f"{x:,.0f}" if x >= 100 else f"{x:.2f}" if x >= 1 else f"{x:.4g}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--top", type=int, default=50)
    ap.add_argument("--sort", choices=["score", "ath", "52w", "pe"], default="score",
                    help="score = low P/E + deep drawdown combined; ath/52w = drawdown only; pe = P/E only")
    ap.add_argument("--max-pe", type=float, help="drop stocks with P/E above this")
    ap.add_argument("--only", choices=["stocks", "crypto"], help="run just one section")
    ap.add_argument("--csv", help="also write the full stock universe to this CSV path")
    ap.add_argument("--workers", type=int, default=8)
    a = ap.parse_args()

    print(f"_Datos: Yahoo Finance, {date.today():%d/%m/%Y}. Precios del subyacente en USD._\n")

    if a.only != "crypto":
        df, fetched = scan_stocks(a.workers)
        if a.csv:
            df.to_csv(a.csv, index=False)
        if a.max_pe:
            df = df[df.pe <= a.max_pe]
        key = {"score": ("score", True), "ath": ("dd_ath", True), "52w": ("dd_52w", True), "pe": ("pe", True)}[a.sort]
        top = df.sort_values(key[0], ascending=key[1]).head(a.top)
        print(f"## CEDEARs — top {len(top)} (orden: {a.sort}; {len(df)} con P/E > 0 de {fetched} con datos)\n")
        print("| # | Ticker | Empresa | P/E | P/E fwd | vs máx hist. | Año máx | vs máx 52s |")
        print("|---|---|---|---|---|---|---|---|")
        for n, r in enumerate(top.itertuples(), 1):
            print(f"| {n} | {r.ticker} | {r.name} | {num(r.pe)} | {num(r.fpe)} | {pct(r.dd_ath)} | "
                  f"{r.ath_date.year} | {pct(r.dd_52w)} |")
        print()

    if a.only != "stocks":
        cr = scan_crypto()
        key = "dd_52w" if a.sort == "52w" else "dd_ath"
        cr = cr.sort_values(key)
        print(f"## Crypto — {len(cr)} (orden: caída desde {'máx 52s' if key == 'dd_52w' else 'ATH'}; sin P/E)\n")
        print("| # | Crypto | Precio USD | vs ATH | Fecha ATH | vs máx 52s | 30d | Historia desde |")
        print("|---|---|---|---|---|---|---|---|")
        for n, r in enumerate(cr.itertuples(), 1):
            print(f"| {n} | {r.ticker} | {money(r.price)} | {pct(r.dd_ath)} | {r.ath_date:%m/%Y} | "
                  f"{pct(r.dd_52w)} | {pct(r.chg_30d)} | {r.since} |")


if __name__ == "__main__":
    main()
