---
name: stock-review
description: >
  Screen the stocks that have a CEDEAR in BYMA for the cheapest and most beaten-down — lowest P/E
  combined with the deepest drop from their highs — plus a table of the top cryptos ranked by drop
  from all-time high. Live data from Yahoo Finance. Use when the user says things like "cedears
  baratos", "top cedears por P/E", "menor price to earning y mayor caída desde máximos", "qué
  cedears están más castigados", "screener de cedears", "cryptos más caídas desde el ATH", or
  "/stock-review".
argument-hint: '[--top N] [--sort score|ath|52w|pe] [--max-pe X] [--only stocks|crypto]'
---

## What this does

Runs `scripts/run.sh`, which on first use creates a private venv at `~/.cache/stock-review/venv`
(yfinance + pandas) and then downloads, for ~300 stocks with a CEDEAR and ~36 cryptos:

- **Stocks:** trailing P/E, forward P/E, full price history → drop from all-time high and from the
  52-week high. Only P/E > 0 is kept (losses have no meaningful P/E).
- **Crypto:** price history → drop from ATH, from the 52-week high, and 30-day change. Crypto has no
  earnings, so it is never mixed into the stock ranking — it is its own table.

The default stock order (`score`) is the average of two percentile ranks: P/E (lower is better) and
drop from all-time high (deeper is better). Both weigh the same.

It is read-only and touches nothing outside `~/.cache/stock-review/`. Takes about 1–2 minutes
(one Yahoo call per stock). Respond in the language the user is using.

## Run it

```bash
~/.claude-personal/skills/stock-review/scripts/run.sh [flags] 2>/dev/null
```

Use whichever config dir has the skill (`~/.claude` or `~/.claude-personal`). It needs network: in a
sandboxed session, run it with the sandbox disabled. stderr carries `sin datos: X` for tickers Yahoo
did not return; read it if a known name is missing.

| flag | effect |
| --- | --- |
| `--top N` | stocks to show (default 50). Crypto always shows all. |
| `--sort score` | default: low P/E + deep drop from ATH combined. |
| `--sort ath` / `--sort 52w` | by drop from all-time high / 52-week high only. `52w` also re-orders crypto. |
| `--sort pe` | by P/E only. |
| `--max-pe X` | drop stocks with P/E above X. |
| `--only stocks` / `--only crypto` | one section. |
| `--csv PATH` | also dump the full stock universe (every column) for follow-up questions. |

Map what the user asks to flags: "ordenalas por caída desde máximos" → `--sort ath`; "caída
actual / del último año" → `--sort 52w`; "solo cryptos" → `--only crypto`. If they then want the
same list re-sorted, use `--csv` on the first run and re-sort the CSV instead of downloading again.

## Report

Paste the tables the script prints as they are, then add a short **Ojo con** list. Check the data
for these traps every time and name the tickers that fall into them:

- **Ancient highs.** An all-time high from decades ago (AIG 2000, Coeur 1987, Ericsson 2000, Citi
  2006) puts a stock at the top of a drop ranking for a crash nobody alive in the market cares about.
  Point at the 52-week column for those.
- **One-off P/E.** A trailing P/E far below the forward one (e.g. 2 vs 7, or 4 vs 52) usually means a
  one-time gain — a tax benefit, an asset revaluation (common in Argentine real estate: IRSA,
  Cresud). Flag any with forward P/E more than ~2× the trailing one.
- **Short crypto history.** Yahoo's crypto data starts in 2014 (BTC, LTC) or Nov 2017 (most of the
  rest); the "Historia desde" column says which. An ATH before that start is missed.
- **Prices are the underlying in USD**, not the CEDEAR in pesos. The CEDEAR's peso price also moves
  with the CCL exchange rate, which this does not capture.

Close with the strongest names: those that rank well on both criteria *and* have a low forward P/E.
This is a screen, not advice — say so in one line, no more.

## Maintaining the lists

`CEDEARS` and `CRYPTOS` at the top of `scripts/screener.py` are hard-coded. BYMA adds CEDEARs a few
times a year; if the user names one that is missing, add its Yahoo symbol. A crypto whose bare
symbol is taken on Yahoo needs its numeric suffix (`SUI20947-USD`); look it up on
finance.yahoo.com. TON is left out: `TON-USD` is a different token and `TON11419-USD` returns one day
of history.
