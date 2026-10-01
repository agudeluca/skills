"""Argentine bonds screener: live prices (data912) + payment schedules (argen.bond, cached).

Prints markdown tables to stdout; warnings go to stderr. Stdlib only.

Conventions, ported from ~/projects/expenses/src/bonos/ytm.ts and validated there against
argen.bond (AL29, 2026-08-30: TIR, parity and modified duration all reproduced):
- every amount is per 100 of ORIGINAL face value; amortized bonds keep that base.
- act/365, annual compounding, discount against the CLEAN price as quoted.
"""
import argparse, json, sys, time, urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import date
from pathlib import Path

DATA = Path(__file__).resolve().parent.parent / "data"
D912 = "https://data912.com/live/"
ADATOS = "https://api.argentinadatos.com/v1/"


def get_json(url, tries=4):
    # data912 resets connections after a few back-to-back runs; it recovers within seconds.
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r)
        except Exception:
            if i == tries - 1:
                raise
            time.sleep(3 * (i + 1))


def iso(s):
    return date.fromisoformat(s)


# ---------- schedules ----------

def load_schedules():
    cache = json.loads((DATA / "schedules.json").read_text())
    bonos = cache["bonos"]
    over = DATA / "overrides.json"
    if over.exists():
        # Hand corrections win over the scrape. Each must carry "fuente".
        for t, b in json.loads(over.read_text()).items():
            bonos[t] = {**bonos.get(t, {}), **b}
    return cache["scrapedAt"][:10], bonos


def kind(b):
    """usd | pesos | cer | tamar | badlar | dlinked | dual — what the cash flows are denominated in."""
    f = b.get("ficha", {})
    cupon, pago, nombre = f.get("Tipo Cupón", ""), f.get("Moneda Pago", ""), (b.get("nombre") or "").upper()
    # D30O6 & co. are dollar-linked by name but the ficha calls them "Tasa Fija / Pesos".
    if cupon == "Dolar linked" or "VINCULADA AL D" in nombre or "VINC. USD" in nombre:
        return "dlinked"
    # Duals (TTD26, TXMJ8) pay the better of two rates; the ficha leaves the coupon type blank and
    # the scraped total is an estimate, so a fixed-rate TIR on it means nothing.
    if "DUAL" in nombre or not cupon:
        return "dual"
    if cupon in ("CER", "TAMAR", "BADLAR"):
        return cupon.lower()
    # A foreign-law bond paying pesos is a scrape error (CO35, NDT5C come out as "Pesos").
    return "usd" if pago.startswith("Dolar") or f.get("Ley") in ("NY", "ENG") else "pesos"


# ---------- math (port of ytm.ts) ----------

def futuro(flujo, hoy):
    return sorted((f for f in flujo if not f["pagado"] and iso(f["fecha"]) > hoy), key=lambda f: f["fecha"])


def years(hoy, d):
    return (iso(d) - hoy).days / 365


def accrued(flujo, hoy):
    fut = futuro(flujo, hoy)
    prev = sorted((f for f in flujo if iso(f["fecha"]) <= hoy), key=lambda f: f["fecha"])
    if not fut or not prev:
        return 0.0
    ini, fin = iso(prev[-1]["fecha"]), iso(fut[0]["fecha"])
    periodo = (fin - ini).days
    return fut[0]["interes"] * (hoy - ini).days / periodo if periodo > 0 else 0.0


def pv(fut, r, hoy):
    return sum(f["total"] / (1 + r) ** years(hoy, f["fecha"]) for f in fut)


def ytm(flujo, precio, hoy):
    """Bisection on [-90%, 500%]; None if no future flows or the root is outside (currency mismatch)."""
    fut = futuro(flujo, hoy)
    if not fut or not precio or precio <= 0:
        return None
    lo, hi = -0.9, 5.0
    for _ in range(200):
        mid = (lo + hi) / 2
        lo, hi = (mid, hi) if pv(fut, mid, hoy) > precio else (lo, mid)
    r = (lo + hi) / 2
    return r if abs(pv(fut, r, hoy) - precio) <= precio * 1e-6 else None


def mod_duration(flujo, r, hoy):
    fut = futuro(flujo, hoy)
    tot = sum(f["total"] / (1 + r) ** years(hoy, f["fecha"]) for f in fut)
    mac = sum(years(hoy, f["fecha"]) * f["total"] / (1 + r) ** years(hoy, f["fecha"]) for f in fut)
    return mac / tot / (1 + r) if tot else None


def paridad(flujo, precio, hoy):
    fut = futuro(flujo, hoy)
    if not fut or not fut[0]["residual"]:
        return None
    return precio / (fut[0]["residual"] + accrued(flujo, hoy)) * 100


def vida_promedio(flujo, hoy):
    fut = futuro(flujo, hoy)
    cap = sum(f["amort"] for f in fut)
    return sum(f["amort"] * years(hoy, f["fecha"]) for f in fut) / cap if cap > 0 else None


# ---------- prices ----------

def load_prices():
    rows = []
    for ep in ("arg_bonds", "arg_notes"):
        try:
            rows += get_json(D912 + ep)
        except Exception as e:
            print(f"data912 {ep}: {e}", file=sys.stderr)
    return {r["symbol"]: r for r in rows}


def last(q):
    """Last trade, falling back to the bid/ask midpoint when nothing traded today."""
    if not q:
        return None
    if q.get("c"):
        return q["c"]
    b, a = q.get("px_bid") or 0, q.get("px_ask") or 0
    return (a + b) / 2 if a and b else None


def usd_quote(t, b, px, bonos):
    """USD price per 100 VN, in the currency the bond PAYS: discounting cable flows against a MEP
    price (or vice versa) mixes in the MEP/CCL gap. MEP payers use the D line, cable payers the C
    line; the other one is the fallback. Returns (price, liq, quote, fallback_used).

    BOPREAL lists its USD lines as schedule tickers of their own (BPA7D, BPA7C next to BPOA7):
    keep only the line in the paying currency and drop the peso ticker.
    """
    pays = "C" if b.get("ficha", {}).get("Moneda Pago") == "Dolar Cable" else "D"
    if t[-1] in "DC" and t[:-1] not in bonos and last(px.get(t)) and last(px[t]) < 1000:
        return (last(px[t]), "MEP" if t[-1] == "D" else "CCL", px[t], False) if t[-1] == pays else (None,) * 4
    if t.startswith("BPO"):
        return (None,) * 4
    for suf in (pays, "C" if pays == "D" else "D"):
        if last(px.get(t + suf)):
            return last(px[t + suf]), "MEP" if suf == "D" else "CCL", px[t + suf], suf != pays
    return (None,) * 4


# ---------- report ----------

def pct(x, d=2):
    return "—" if x is None else f"{x * 100:.{d}f}%"


def n(x, d=2):
    return "—" if x is None else f"{x:,.{d}f}"


def build(bonos, px, hoy, min_vol, all_issuers):
    out = []
    for t, b in bonos.items():
        k, flujo = kind(b), b.get("flujo", [])
        fut = futuro(flujo, hoy)
        if not fut:
            continue
        fallback = False
        if k == "usd":
            precio, liq, q, fallback = usd_quote(t, b, px, bonos)
        else:
            q = px.get(t)
            precio, liq = last(q), "ARS"
            # Peso bonds' D/C lines (XN6D at 0.08) are USD quotes, not bonds of their own.
            if precio is not None and precio < 5:
                continue
        if not precio:
            continue
        if not all_issuers and b.get("ficha", {}).get("Emisora") not in ("Argentina", "BCRA"):
            continue
        vol = (q or {}).get("v") or 0
        if vol < min_vol:
            continue
        f = b.get("ficha", {})
        row = dict(t=t, k=k, emisor=f.get("Emisora") or "—", ley=f.get("Ley") or "—", precio=precio, liq=liq,
                   vol=vol, var=(q or {}).get("pct_change"), vto=fut[-1]["fecha"], dias=(iso(fut[-1]["fecha"]) - hoy).days,
                   fallback=fallback, prox=fut[0], ref_tir=b.get("tirMercado"), nombre=b.get("nombre") or "")
        if k in ("usd", "pesos"):
            r = ytm(flujo, precio, hoy)
            if k == "pesos" and r is not None and r < 0:
                print(f"{t}: TIR negativa en pesos, probable bono en otra moneda; salteado", file=sys.stderr)
                continue
            row.update(tir=r, md=mod_duration(flujo, r, hoy) if r is not None else None,
                       par=paridad(flujo, precio, hoy), vida=vida_promedio(flujo, hoy), pagos=len(fut))
        out.append(row)
    return out


def best_plazo_fijo():
    try:
        rows = get_json(ADATOS + "finanzas/tasas/plazoFijo")
        bna = next((r["tnaClientes"] for r in rows if "NACION" in r["entidad"]), None)
        top = max(rows, key=lambda r: r.get("tnaClientes") or 0)
        return bna, top["entidad"].title(), top["tnaClientes"]
    except Exception as e:
        print(f"plazo fijo: {e}", file=sys.stderr)
        return None, None, None


def dolares():
    try:
        d = get_json(ADATOS + "cotizaciones/dolares/")
        latest = {}
        for r in d:
            latest[r["casa"]] = r
        return latest.get("bolsa", {}).get("venta"), latest.get("contadoconliqui", {}).get("venta")
    except Exception as e:
        print(f"dólar: {e}", file=sys.stderr)
        return None, None


SECTIONS = ("usd", "pesos", "ajustables")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", choices=SECTIONS, help="one section")
    ap.add_argument("--ticker", nargs="+", help="detail + full remaining schedule for these base tickers")
    ap.add_argument("--min-vol", type=float, default=1, help="drop lines that traded less than this (default 1: drops no-trade lines)")
    ap.add_argument("--all-issuers", action="store_true", help="include provinces and other issuers beyond the Treasury and BCRA")
    ap.add_argument("--json", help="also dump every computed row to this path")
    a = ap.parse_args()

    hoy = date.today()
    snap, bonos = load_schedules()
    with ThreadPoolExecutor(3) as ex:
        fp, fpf, fd = ex.submit(load_prices), ex.submit(best_plazo_fijo), ex.submit(dolares)
    px, (bna, pf_ent, pf_tna), (mep, ccl) = fp.result(), fpf.result(), fd.result()

    if not px:
        sys.exit("data912 no respondió (ni con reintentos). Probá de nuevo en un minuto.")
    rows = build(bonos, px, hoy, 0 if a.ticker else a.min_vol, a.all_issuers or bool(a.ticker))
    if a.json:
        Path(a.json).write_text(json.dumps(rows, default=str, ensure_ascii=False, indent=1))

    print(f"_Precios: data912 en vivo, {hoy:%d/%m/%Y}. Cronogramas: argen.bond, scrapeados el {snap}. "
          f"MEP {n(mep, 0)} · CCL {n(ccl, 0)}._\n")

    if a.ticker:
        detail(a.ticker, bonos, rows, hoy)
        return

    if a.only in (None, "usd"):
        usd = [r for r in rows if r["k"] == "usd"]
        usd.sort(key=lambda r: (r["emisor"] != "Argentina", r["vto"]))
        print("## Hard dollar (precio USD por 100 VN, en la moneda en que paga: MEP o cable)\n")
        print("| Ticker | Emisor | Ley | Precio | Liq. | TIR | MD | Paridad | Vida prom. | Vto | Próx. pago | Var. día |")
        print("|---|---|---|---|---|---|---|---|---|---|---|---|")
        for r in usd:
            p = r["prox"]
            print(f"| {r['t']} | {r['emisor']} | {r['ley']} | {n(r['precio'])} | {r['liq']}{'*' if r['fallback'] else ''} | {pct(r['tir'])} | "
                  f"{n(r['md'])} | {n(r['par'], 1)}% | {n(r['vida'], 1)}a | {iso(r['vto']):%m/%Y} | "
                  f"{iso(p['fecha']):%d/%m/%y} · {n(p['total'])} | {n(r['var'])}% |")
        # Both legs in MEP, the market convention: otherwise the MEP/CCL gap swamps the law premium.
        def tir_mep(t):
            q = last(px.get(t + "D"))
            return ytm(bonos[t]["flujo"], q, hoy) if q and t in bonos else None
        pairs = [(l, g, tir_mep(l), tir_mep(g)) for l, g in
                 (("AL29", "GD29"), ("AL30", "GD30"), ("AL35", "GD35"), ("AE38", "GD38"), ("AL41", "GD41"))]
        pairs = [p for p in pairs if p[2] is not None and p[3] is not None]
        if any(r["fallback"] for r in usd):
            print("\n\\* sin precio en la moneda de pago; se usó la otra línea, así que la TIR incluye la brecha MEP/CCL.")
        if pairs:
            print("\n**Spread ley local vs NY** (TIR local − TIR NY, ambos en MEP, en pb): " + " · ".join(
                f"{l}/{g} {(tl - tg) * 1e4:+.0f}" for l, g, tl, tg in pairs))
        print()

    if a.only in (None, "pesos"):
        ps = sorted((r for r in rows if r["k"] == "pesos" and r["tir"] is not None), key=lambda r: r["vto"])
        print("## Pesos a tasa fija — LECAP / BONCAP (precio ARS por 100 VN)\n")
        print("| Ticker | Precio | Vto | Días | TEM | TNA | TEA (TIR) | Pagos | Var. día |")
        print("|---|---|---|---|---|---|---|---|---|")
        for r in ps:
            tem = (1 + r["tir"]) ** (30 / 365) - 1
            print(f"| {r['t']} | {n(r['precio'], 3)} | {iso(r['vto']):%d/%m/%y} | {r['dias']} | {pct(tem)} | "
                  f"{pct(tem * 365 / 30, 1)} | {pct(r['tir'], 1)} | {r['pagos']} | {n(r['var'])}% |")
        if bna:
            print(f"\n**Referencia plazo fijo (TNA clientes):** Banco Nación {pct(bna, 1)} "
                  f"(TEM {pct(bna * 30 / 365)}) · mejor: {pf_ent} {pct(pf_tna, 1)}")
        print()

    if a.only in (None, "ajustables"):
        adj = sorted((r for r in rows if r["k"] not in ("usd", "pesos")), key=lambda r: (r["k"], r["vto"]))
        print("## Ajustables — CER, TAMAR, BADLAR, duales, dollar linked (precio ARS)\n")
        print(f"_La TIR es la que publicó argen.bond el {snap}, no la de hoy: los flujos están en moneda "
              f"indexada y recalcularla con el precio en vivo pide el coeficiente del día._\n")
        print("| Ticker | Tipo | Precio | Vto | TIR ref. | Var. día |")
        print("|---|---|---|---|---|---|")
        for r in adj:
            print(f"| {r['t']} | {r['k'].upper()} | {n(r['precio'])} | {iso(r['vto']):%m/%Y} | "
                  f"{n(r['ref_tir'])}% | {n(r['var'])}% |")


def detail(tickers, bonos, rows, hoy):
    by = {r["t"]: r for r in rows}
    for t in (x.upper() for x in tickers):
        b = bonos.get(t)
        if not b:
            print(f"**{t}**: no está en el cache de cronogramas. Corré `refresh.py {t}`.\n")
            continue
        r = by.get(t)
        f = b.get("ficha", {})
        print(f"## {t} — {b.get('nombre')}\n")
        print(f"Emisor {f.get('Emisora')} · Ley {f.get('Ley')} · Paga en {f.get('Moneda Pago')} · "
              f"{f.get('Tipo Cupón')} · {f.get('Frecuencia')} · {f.get('Amortización')}\n")
        if r:
            line = f"Precio {n(r['precio'])} ({r['liq']})"
            if r.get("tir") is not None:
                line += f" · TIR {pct(r['tir'])} · MD {n(r['md'])} · Paridad {n(r['par'], 1)}% · Vida prom. {n(r['vida'], 1)} años"
            else:
                line += f" · TIR ref. argen.bond {n(r['ref_tir'])}%"
            print(line + "\n")
        else:
            print("Sin precio en vivo en data912.\n")
        print("| Fecha | Interés | Amort. | Total | Residual |")
        print("|---|---|---|---|---|")
        for p in futuro(b["flujo"], hoy):
            print(f"| {iso(p['fecha']):%d/%m/%Y} | {n(p['interes'], 3)} | {n(p['amort'], 3)} | {n(p['total'], 3)} | {n(p['residual'], 1)}% |")
        print()


if __name__ == "__main__":
    main()
