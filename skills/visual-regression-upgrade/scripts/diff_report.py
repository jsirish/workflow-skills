#!/usr/bin/env python3
"""Diff matched PNG pairs and produce a self-contained HTML report.

Usage:
    diff_report.py --in ./vr-out --out ./vr-out/report
"""
import argparse
import base64
import html
import io
import json
from pathlib import Path

import numpy as np
from PIL import Image


PASS_THRESHOLD = 0.005   # < 0.5%
WARN_THRESHOLD = 0.05    # 0.5–5%
PIXEL_TOLERANCE = 12     # per-channel delta below this counts as unchanged


def pad_to_same_height(a: Image.Image, b: Image.Image):
    """Make both images the same height/width — pad shorter with white."""
    # First match width (rare mismatch but possible)
    max_w = max(a.width, b.width)
    if a.width != max_w:
        new = Image.new("RGB", (max_w, a.height), "white")
        new.paste(a, (0, 0))
        a = new
    if b.width != max_w:
        new = Image.new("RGB", (max_w, b.height), "white")
        new.paste(b, (0, 0))
        b = new
    max_h = max(a.height, b.height)
    if a.height != max_h:
        new = Image.new("RGB", (max_w, max_h), "white")
        new.paste(a, (0, 0))
        a = new
    if b.height != max_h:
        new = Image.new("RGB", (max_w, max_h), "white")
        new.paste(b, (0, 0))
        b = new
    return a, b


def diff_pair(prod_img: Image.Image, local_img: Image.Image):
    prod_img = prod_img.convert("RGB")
    local_img = local_img.convert("RGB")
    prod_img, local_img = pad_to_same_height(prod_img, local_img)

    a = np.asarray(prod_img, dtype=np.int16)
    b = np.asarray(local_img, dtype=np.int16)
    delta = np.abs(a - b).max(axis=2)            # per-pixel max channel delta
    mask = delta > PIXEL_TOLERANCE               # boolean H×W
    diff_pct = float(mask.mean())

    # Build annotated diff: 50% blend of both, with changed pixels punched red.
    blend = ((a + b) // 2).astype(np.uint8)
    overlay = blend.copy()
    overlay[mask] = [255, 30, 30]
    # Soft halo: dim non-changed by 30% so red pops
    if mask.any():
        unchanged = ~mask
        overlay[unchanged] = (overlay[unchanged].astype(np.int16) * 7 // 10).astype(np.uint8)
    diff_img = Image.fromarray(overlay, mode="RGB")
    return diff_pct, prod_img, local_img, diff_img


def classify(pct):
    if pct < PASS_THRESHOLD:
        return "PASS"
    if pct < WARN_THRESHOLD:
        return "WARN"
    return "FAIL"


def to_data_uri(img: Image.Image, max_width=1200, quality=80):
    """Encode as JPEG data URI to keep HTML size manageable."""
    if img.width > max_width:
        ratio = max_width / img.width
        img = img.resize((max_width, int(img.height * ratio)), Image.LANCZOS)
    buf = io.BytesIO()
    img.convert("RGB").save(buf, format="JPEG", quality=quality, optimize=True)
    return "data:image/jpeg;base64," + base64.b64encode(buf.getvalue()).decode()


HTML_TEMPLATE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Visual Regression Report</title>
<style>
  :root {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }}
  body {{ margin: 0; padding: 24px; background: #f6f7f9; color: #1a1a1a; }}
  h1 {{ margin: 0 0 4px; }}
  .meta {{ color: #666; margin-bottom: 24px; font-size: 13px; }}
  table.summary {{ border-collapse: collapse; width: 100%; background: #fff; box-shadow: 0 1px 2px rgba(0,0,0,.05); margin-bottom: 32px; }}
  table.summary th, table.summary td {{ padding: 10px 14px; text-align: left; border-bottom: 1px solid #eee; font-size: 14px; }}
  table.summary th {{ background: #fafbfc; font-weight: 600; }}
  table.summary tr {{ cursor: pointer; }}
  table.summary tr:hover {{ background: #f0f4ff; }}
  .badge {{ display: inline-block; padding: 2px 10px; border-radius: 999px; font-size: 12px; font-weight: 600; color: #fff; }}
  .badge.PASS {{ background: #2ea44f; }}
  .badge.WARN {{ background: #d97706; }}
  .badge.FAIL {{ background: #cf222e; }}
  .badge.ERROR {{ background: #6b7280; }}
  .page {{ background: #fff; border-radius: 6px; padding: 16px; margin-bottom: 24px; box-shadow: 0 1px 2px rgba(0,0,0,.05); }}
  .page h2 {{ margin: 0 0 8px; font-size: 18px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }}
  .page .stats {{ color: #555; font-size: 13px; margin-bottom: 12px; }}
  .toggles {{ margin-bottom: 8px; }}
  .toggles button {{ background: #eef0f3; border: 1px solid #d0d7de; padding: 4px 10px; margin-right: 6px; border-radius: 4px; cursor: pointer; font-size: 12px; }}
  .toggles button.active {{ background: #0969da; color: #fff; border-color: #0969da; }}
  .triple {{ display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 8px; }}
  .triple > div {{ display: flex; flex-direction: column; }}
  .triple label {{ font-size: 11px; color: #666; text-transform: uppercase; letter-spacing: .04em; margin-bottom: 4px; }}
  .triple img {{ width: 100%; border: 1px solid #d0d7de; border-radius: 4px; display: block; background: #fff; }}
  .triple.single img {{ display: none; }}
  .triple.single .show {{ display: block; }}
  .err {{ color: #cf222e; font-size: 13px; padding: 12px; background: #ffeef0; border-radius: 4px; }}
</style>
</head>
<body>
<h1>Visual Regression Report</h1>
<div class="meta">{meta}</div>

<table class="summary">
  <thead><tr><th>Path</th><th>Diff %</th><th>Status</th></tr></thead>
  <tbody>
    {summary_rows}
  </tbody>
</table>

{page_sections}

<script>
  document.querySelectorAll('table.summary tbody tr').forEach(row => {{
    row.addEventListener('click', () => {{
      const target = document.getElementById(row.dataset.target);
      if (target) target.scrollIntoView({{ behavior: 'smooth', block: 'start' }});
    }});
  }});
  document.querySelectorAll('.toggles').forEach(group => {{
    group.querySelectorAll('button').forEach(btn => {{
      btn.addEventListener('click', () => {{
        const triple = document.getElementById(btn.dataset.target);
        group.querySelectorAll('button').forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
        const mode = btn.dataset.mode;
        if (mode === 'all') {{
          triple.classList.remove('single');
          triple.querySelectorAll('img').forEach(i => i.classList.remove('show'));
        }} else {{
          triple.classList.add('single');
          triple.querySelectorAll('img').forEach(i => i.classList.toggle('show', i.dataset.kind === mode));
        }}
      }});
    }});
  }});
</script>
</body>
</html>
"""


def main():
    ap = argparse.ArgumentParser(description="Diff prod/ vs local/ PNG pairs and emit HTML report.")
    ap.add_argument("--in", dest="in_dir", required=True, help="Directory containing prod/, local/, manifest.json")
    ap.add_argument("--out", dest="out_dir", required=True, help="Output directory for report")
    args = ap.parse_args()

    in_dir = Path(args.in_dir)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    manifest_path = in_dir / "manifest.json"
    if not manifest_path.exists():
        raise SystemExit(f"manifest.json not found at {manifest_path}")
    manifest = json.loads(manifest_path.read_text())

    prod_dir = in_dir / "prod"
    local_dir = in_dir / "local"

    prod_by_slug = {e["slug"]: e for e in manifest.get("prod", [])}
    local_by_slug = {e["slug"]: e for e in manifest.get("local", [])}
    slugs = sorted(set(prod_by_slug) & set(local_by_slug))

    results = []
    summary_rows = []
    page_sections = []

    for i, slug in enumerate(slugs, 1):
        prod_entry = prod_by_slug[slug]
        local_entry = local_by_slug[slug]
        path = prod_entry["path"]
        print(f"[diff {i}/{len(slugs)}] {path}", flush=True)

        prod_file = prod_dir / prod_entry["file"]
        local_file = local_dir / local_entry["file"]

        record = {"path": path, "slug": slug}

        slug_esc = html.escape(slug, quote=True)
        path_esc = html.escape(path, quote=True)

        if not prod_entry.get("ok") or not local_entry.get("ok") or not prod_file.exists() or not local_file.exists():
            record["status"] = "ERROR"
            record["error"] = prod_entry.get("error") or local_entry.get("error") or "missing screenshot"
            record["diff_pct"] = None
            results.append(record)
            error_esc = html.escape(record["error"])
            summary_rows.append(
                f'<tr data-target="page-{slug_esc}"><td><code>{path_esc}</code></td><td>—</td>'
                f'<td><span class="badge ERROR">ERROR</span></td></tr>'
            )
            page_sections.append(
                f'<div class="page" id="page-{slug_esc}"><h2>{path_esc}</h2>'
                f'<div class="err">Capture failed: {error_esc}</div></div>'
            )
            continue

        prod_img = Image.open(prod_file)
        local_img = Image.open(local_file)
        diff_pct, prod_img, local_img, diff_img = diff_pair(prod_img, local_img)
        status = classify(diff_pct)
        record["diff_pct"] = round(diff_pct * 100, 3)
        record["status"] = status

        prod_uri = to_data_uri(prod_img)
        local_uri = to_data_uri(local_img)
        diff_uri = to_data_uri(diff_img)
        record["diff_image_embedded"] = True

        results.append(record)

        summary_rows.append(
            f'<tr data-target="page-{slug_esc}"><td><code>{path_esc}</code></td>'
            f'<td>{record["diff_pct"]:.3f}%</td>'
            f'<td><span class="badge {status}">{status}</span></td></tr>'
        )
        page_sections.append(
            f'''<div class="page" id="page-{slug_esc}">
  <h2>{path_esc}</h2>
  <div class="stats">Diff: <strong>{record["diff_pct"]:.3f}%</strong> · <span class="badge {status}">{status}</span></div>
  <div class="toggles">
    <button data-mode="all" data-target="triple-{slug_esc}" class="active">All three</button>
    <button data-mode="prod" data-target="triple-{slug_esc}">Prod only</button>
    <button data-mode="diff" data-target="triple-{slug_esc}">Diff only</button>
    <button data-mode="local" data-target="triple-{slug_esc}">Local only</button>
  </div>
  <div class="triple" id="triple-{slug_esc}">
    <div><label>Prod</label><img data-kind="prod" src="{prod_uri}"></div>
    <div><label>Diff</label><img data-kind="diff" src="{diff_uri}"></div>
    <div><label>Local</label><img data-kind="local" src="{local_uri}"></div>
  </div>
</div>'''
        )

    (out_dir / "results.json").write_text(json.dumps(results, indent=2))

    vp = manifest.get("viewport", {})
    meta = (
        f'<strong>Prod:</strong> {html.escape(str(manifest.get("prod_base","?")))} &nbsp; '
        f'<strong>Local:</strong> {html.escape(str(manifest.get("local_base","?")))} &nbsp; '
        f'<strong>Viewport:</strong> {html.escape(str(vp.get("width","?")))}×{html.escape(str(vp.get("height","?")))} &nbsp; '
        f'<strong>Captured:</strong> {html.escape(str(manifest.get("finished","?")))}'
    )

    report_html = HTML_TEMPLATE.format(
        meta=meta,
        summary_rows="\n    ".join(summary_rows) or '<tr><td colspan="3">No matched pairs.</td></tr>',
        page_sections="\n".join(page_sections),
    )
    (out_dir / "index.html").write_text(report_html)

    counts = {"PASS": 0, "WARN": 0, "FAIL": 0, "ERROR": 0}
    for r in results:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    print()
    print(f"Done. {counts['PASS']} PASS · {counts['WARN']} WARN · {counts['FAIL']} FAIL · {counts['ERROR']} ERROR")
    print(f"Report: {out_dir / 'index.html'}")


if __name__ == "__main__":
    main()
