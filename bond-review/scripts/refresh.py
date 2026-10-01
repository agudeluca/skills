"""Refresh data/schedules.json from argen.bond. Port of ~/projects/expenses/src/bonos/scrape.ts.

    refresh.py              # whole universe (bases from data912), ~3 min
    refresh.py AL29 GD30    # just these

Schedules are slow data — they only change on a restructuring or a new issue. A ticker that fails
keeps its previous entry; a page whose table shape changed raises instead of overwriting the cache.

What NOT to retry (learned in expenses/):
- argen.bond/sovereign_bonds lists only 3–5 tickers per category without an account. The universe
  comes from data912; the detail pages argen.bond/bonos/<TICKER> open anonymously.
- The URL is /bonos/<TICKER>. An unknown ticker REDIRECTS to the homepage; treat that as missing.
"""
import html as H, json, re, sys, time, urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

from bonds import DATA, D912, get_json

BASE = "https://argen.bond/bonos/"
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126 Safari/537.36"


class NoSchedule(Exception):
    """The page exists but argen.bond publishes no schedule for it. A gap in the source, not an error."""


def norm(s):
    return re.sub(r"\s+", " ", H.unescape(re.sub(r"<[^>]*>", " ", s))).strip()


def pct(raw):
    m = re.search(r"(-?[\d.]+)\s*%", raw.replace(" ", ""))
    return float(m.group(1)) if m else None


def amount(raw):
    """Spanish format: 1.234,56 → 1234.56."""
    c = re.sub(r"^(-?)(?:ARS|USD|EUR)", r"\1", re.sub(r"[$\s]", "", raw), flags=re.I)
    c = c.replace(".", "").replace(",", ".")
    return float(c) if re.fullmatch(r"-?\d+(\.\d+)?", c) else None


def fecha(raw):
    m = re.search(r"(\d{2})/(\d{2})/(\d{4})", raw)
    return f"{m.group(3)}-{m.group(2)}-{m.group(1)}" if m else None


def header_metric(page, label):
    m = re.search(rf">\s*{label}\s*</p>\s*<p[^>]*>([^<]*)</p>", page, re.I)
    return norm(m.group(1)) if m else None


def parse(page, ticker):
    tb = re.search(r"<tbody[^>]*>([\s\S]*?)</tbody>", page, re.I)
    flujo, raw_rows = [], 0
    for attrs, body in re.findall(r"<tr([^>]*)>([\s\S]*?)</tr>", tb.group(1) if tb else ""):
        cells = re.findall(r"<td[^>]*>([\s\S]*?)</td>", body)
        raw_rows += bool(cells)
        if len(cells) != 5 or not (d := fecha(norm(cells[0]))):
            continue
        i, a = pct(norm(cells[1])), pct(norm(cells[2]))
        tot = amount(norm(cells[3]))
        flujo.append(dict(fecha=d, interes=i or 0, amort=a or 0, total=tot if tot is not None else (i or 0) + (a or 0),
                          residual=pct(norm(cells[4])) or 0,
                          # Either signal can change alone in a redesign, so accept both.
                          pagado=bool(re.search(r"past-payment", attrs) or re.search(r">\s*Pago\s*<", cells[0]))))

    meta = re.search(r'<meta\s+name="description"\s+content="([^"]*)"', page, re.I)
    desc = H.unescape(meta.group(1)) if meta else ""
    nombre = re.search(r"\(([^)]+)\)", desc)
    if not flujo:
        if raw_rows == 0 and nombre:
            raise NoSchedule(ticker)
        raise RuntimeError(f"{ticker}: no se encontró el flujo — puede haber cambiado el HTML de argen.bond")

    tir = re.search(r"TIR:\s*(-?[\d.]+)\s*%", desc, re.I)
    par = re.search(r"Paridad:\s*(-?[\d.]+)\s*%", desc, re.I)
    precio = moneda = None
    if (k := page.find("Último Precio")) >= 0:
        spans = [norm(s) for s in re.findall(r"<span[^>]*>([^<]*)</span>", page[k:k + 700])]
        precio = next((v for v in map(amount, spans) if v is not None), None)
        moneda = next((s for s in spans if re.fullmatch(r"pesos|d[óo]lares|usd|ars", s, re.I)), None)
    dur, cup = header_metric(page, "Duration"), header_metric(page, "Tasa Cup[óo]n")
    ficha = {norm(k): norm(v) for k, v in re.findall(r"<dt[^>]*>([\s\S]*?)</dt>\s*<dd[^>]*>([\s\S]*?)</dd>", page)
             if norm(k) and norm(v)}
    return dict(ticker=ticker, nombre=nombre.group(1).strip() if nombre else None, cupon=pct(cup) if cup else None,
                tirMercado=float(tir.group(1)) if tir else None, paridad=float(par.group(1)) if par else None,
                duration=float(dur) if dur and re.fullmatch(r"-?[\d.]+", dur) else None,
                precioReferencia=precio, monedaPrecio=moneda, ficha=ficha,
                flujo=sorted(flujo, key=lambda f: f["fecha"]))


def fetch(ticker):
    req = urllib.request.Request(BASE + ticker, headers={"User-Agent": UA})
    for i in range(3):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                if not r.geturl().rstrip("/").endswith("/bonos/" + ticker):
                    return ticker, None, "redirect (no existe)"
                return ticker, parse(r.read().decode("utf-8", "replace"), ticker), None
        except NoSchedule:
            return ticker, None, "sin cronograma en argen.bond"
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return ticker, None, "404"
            err = str(e)
        except Exception as e:
            err = str(e)
        time.sleep(2 * (i + 1))
    return ticker, None, err


def bases():
    syms = {r["symbol"] for ep in ("arg_bonds", "arg_notes") for r in get_json(D912 + ep)}
    # AL29D/AL29C → AL29, but only when the stripped ticker also trades (BA37D, DS6D are bases).
    return sorted({s[:-1] if s[-1] in "DC" and s[:-1] in syms else s for s in syms})


def main():
    path = DATA / "schedules.json"
    cache = json.loads(path.read_text()) if path.exists() else {"bonos": {}}
    tickers = [t.upper() for t in sys.argv[1:]] or bases()
    print(f"scrapeando {len(tickers)} tickers…", file=sys.stderr)
    ok, kept, skipped = 0, [], []
    with ThreadPoolExecutor(4) as ex:
        for t, data, err in ex.map(fetch, tickers):
            if data:
                cache["bonos"][t] = data
                ok += 1
            elif t in cache["bonos"]:
                kept.append(f"{t} ({err})")
            else:
                skipped.append(f"{t} ({err})")
    cache["scrapedAt"] = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    path.write_text(json.dumps(cache, ensure_ascii=False, indent=1) + "\n")
    print(f"ok {ok} · conservados {len(kept)} · salteados {len(skipped)} · total en cache {len(cache['bonos'])}")
    if kept:
        print("conservé la entrada anterior de: " + ", ".join(kept))
    if skipped:
        print("sin datos: " + ", ".join(skipped))


if __name__ == "__main__":
    main()
