---
name: bond-review
description: >
  Screen Argentine bonds with live prices: hard-dollar sovereigns and BOPREAL (TIR, modified
  duration, parity, average life, next payment, local-vs-NY law spread), peso fixed-rate LECAP /
  BONCAP (TEM, TNA, TEA against the plazo fijo rate), and CER / TAMAR / BADLAR / dual / dollar-linked
  bonds; or one ticker's full remaining payment schedule. Use when the user says things like
  "bonos argentinos", "cómo están los bonos", "TIR de los soberanos", "AL30 vs GD30", "lecaps",
  "qué rinde una lecap", "curva de bonos", "cronograma de pagos de GD35", "cuándo paga AL29", or
  "/bond-review".
argument-hint: '[--only usd|pesos|ajustables] [--ticker T…] [--all-issuers] | refresh [T…]'
---

## What this does

`scripts/run.sh` combines three sources (stdlib Python, no venv):

| need | source |
| --- | --- |
| live price, volume, daily change | data912.com `/live/arg_bonds` + `/live/arg_notes` (keyless) |
| payment schedule: coupons, amortizations, residual, ficha (law, currency, coupon type) | argen.bond `/bonos/<TICKER>`, cached in `data/schedules.json` |
| MEP / CCL, plazo fijo TNA by bank | api.argentinadatos.com |

and computes TIR, modified duration, parity and average life itself, with the convention ported
from `~/projects/expenses/src/bonos/ytm.ts`: per 100 of original face value, act/365, discounting
the **clean** price. That convention reproduces argen.bond's TIR, parity and duration to the
fourth decimal (AL29 at 54.02 on 2026-08-30 → 8.0747%, 89.9063%, 1.4316).

Read-only except `refresh`, which rewrites `data/schedules.json`. Respond in the user's language.

## Run it

```bash
~/.claude-personal/skills/bond-review/scripts/run.sh [flags] 2>/dev/null
```

Use whichever config dir has the skill. Needs network: in a sandboxed session, run with the
sandbox disabled. stderr carries data912 retries and skipped tickers.

| flag | effect |
| --- | --- |
| *(none)* | three sections: hard dollar, pesos tasa fija, ajustables |
| `--only usd\|pesos\|ajustables` | one section |
| `--ticker AL30 GD35` | ficha, live metrics and the full remaining schedule of each (base ticker, no D/C) |
| `--all-issuers` | add provinces and other issuers (default: Treasury + BCRA only) |
| `--min-vol N` | hide lines that traded less than N today (default 1: hides no-trade lines) |
| `--json PATH` | dump every computed row |

`run.sh refresh [TICKER…]` re-scrapes schedules from argen.bond: the whole universe (~170 bases,
~3 min) or just the named tickers. Do it when a ticker is missing ("no está en el cache"), after a
new LECAP/BONCAP is issued, or when the snapshot date in the header is more than ~2 months old.
Then commit `data/schedules.json` in `~/projects/skills` so the next machine gets it.

## Report

Paste the tables as printed, then a short **Ojo con** list. Check every time:

- **Price in the paying currency.** USD bonds are discounted against the line in the currency they
  pay: AL/AE/BOPREAL pay MEP (D line), GD/BA37D pay cable (C line). A `*` in "Liq." means that line
  had no price and the other one was used, so that TIR carries the ~4% MEP/CCL gap.
- **Law spread is measured in MEP for both legs** (market convention), so it is not the
  difference of the two TIR columns above it.
- **Ajustables' TIR is argen.bond's, as of the snapshot date** in the header — not today's.
  Their flows are in indexed currency (CER, TAMAR, USD for dollar-linked) and redoing the math with
  today's price needs the day's coefficient, which this does not fetch. Say so; do not present it
  as live.
- **LECAP vs plazo fijo:** compare TEM against the plazo fijo TEM printed under the table. A LECAP
  is fixed until maturity; a plazo fijo renews at whatever rate exists then.
- **argen.bond's own TIR differs a bit from ours** for USD bonds: it converts its peso reference
  price at its own MEP. Ours uses the USD line directly, which is what the user can actually buy.

Close with what stands out (steepest part of the curve, widest law spread, best LECAP TEM) in two
or three lines. Screen, not advice — one line, no more.

## Known source quirks (do not re-investigate)

- `api.argentinadatos.com/v1/finanzas/rendimientos` is **not** bonds: it is crypto-wallet APYs
  (nexo, belo, lemon…). Only `tasas/plazoFijo` and `cotizaciones/dolares` are used.
- `argen.bond/sovereign_bonds` is gated to 3–5 tickers per category; the detail pages are not.
  An unknown ticker redirects to the homepage — `refresh.py` treats that as missing.
- A ticker that fails on refresh **keeps its previous entry**; a page whose table shape changed
  raises instead of overwriting.
- Peso bonds also list D/C lines (TX28D, XN6D at ~0.08): they are USD quotes, not bonds. The suffix
  does not tell the paying currency — the ficha's "Moneda Pago" does.
- Dual bonds (TTD26, TXMJ8, TXMD8: fixed/TAMAR or CER/TAMAR) have a blank coupon type in the
  ficha and an estimated final payment; they go to ajustables with argen.bond's TIR.
- The ficha marks some foreign-law provincial bonds as paying "Pesos" (CO35, NDT5C). Foreign law is
  treated as USD.
- BOPREAL lists its USD lines as tickers of their own (BPA7D/BPA7C next to the peso BPOA7). Only the
  line in the paying currency (MEP) is kept.
- `data912` resets connections after a few back-to-back runs; `get_json` retries with backoff and
  the script exits with a clear message if prices never arrive.

## Overrides

`data/overrides.json` (optional) maps a ticker to fields that win over the scrape — to fix a
mis-parsed schedule or add a bond argen.bond lacks. Every override **must** carry `"fuente"`: a
schedule without provenance is indistinguishable from an invented one.

Out of scope for now: obligaciones negociables (data912 `/live/arg_corp`, ~600 of them; adding
it means one more endpoint in `load_prices` and `refresh.bases` and ~13 min of scraping), live CER
real yields, convexity and DV01.
