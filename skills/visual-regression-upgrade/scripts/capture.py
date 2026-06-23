#!/usr/bin/env python3
"""Capture full-page screenshots of matching URLs on two environments.

Usage:
    capture.py --prod https://prod.example.com --local https://uat.example.com \
               --paths "/,/about,/contact" --out ./vr-out
"""
import argparse
import getpass
import hashlib
import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from playwright.sync_api import sync_playwright


def resolve_auth(cli_auth):
    """Resolve --auth in priority order: explicit CLI > env > prompt.

    CLI accepts:
      user:pass      → use directly (visible in argv — discouraged)
      env:VAR        → read user:pass from environment variable VAR
      env:USER/PASS  → read user from env USER, pass from env PASS
      prompt         → interactively prompt for username + password
    """
    if not cli_auth:
        return None
    if cli_auth == "prompt":
        user = input("HTTP auth username: ").strip()
        pw = getpass.getpass("HTTP auth password: ")
        return f"{user}:{pw}"
    if cli_auth.startswith("env:"):
        spec = cli_auth[4:]
        if "/" in spec:
            user_var, pass_var = spec.split("/", 1)
            user = os.environ.get(user_var, "").strip()
            pw = os.environ.get(pass_var, "")
            if not user or not pw:
                raise SystemExit(f"env vars {user_var}/{pass_var} not set or empty")
            return f"{user}:{pw}"
        val = os.environ.get(spec, "")
        if not val:
            raise SystemExit(f"env var {spec} not set or empty")
        return val
    return cli_auth


def slugify(path: str) -> str:
    """Produce a filesystem-safe, collision-resistant slug for a path.

    Long paths are truncated, and a short hash of the original path is
    appended so distinct inputs never collide (e.g. /foo/bar vs /foo-bar,
    or two long paths sharing the same prefix).
    """
    raw = path.strip("/") or "home"
    sanitized = re.sub(r"[^a-zA-Z0-9._-]+", "-", raw)[:100] or "home"
    digest = hashlib.sha1(path.encode("utf-8")).hexdigest()[:8]
    return f"{sanitized}-{digest}"


def parse_viewport(s: str):
    m = re.match(r"^(\d+)x(\d+)$", s)
    if not m:
        raise argparse.ArgumentTypeError(f"viewport must be WxH, got {s!r}")
    return {"width": int(m.group(1)), "height": int(m.group(2))}


def load_json(path):
    if not path:
        return None
    return json.loads(Path(path).read_text())


def auto_scroll(page):
    """Trigger lazy-load by scrolling to the bottom in steps.

    Bounded by both a maximum iteration count and a maximum elapsed time
    so infinite-scroll pages (where scrollHeight keeps growing as new
    content loads) can't hang the capture until the outer timeout fires.
    """
    page.evaluate(
        """async () => {
            await new Promise((resolve) => {
                const step = 400;
                const maxIterations = 200;          // ~80s worth of steps at 80ms
                const maxScroll = 50000;            // 50k px hard cap on page height
                const startedAt = Date.now();
                const maxElapsedMs = 8000;          // 8s wall-clock cap
                let total = 0;
                let iterations = 0;
                const timer = setInterval(() => {
                    iterations += 1;
                    window.scrollBy(0, step);
                    total += step;
                    const reachedEnd = total >= document.body.scrollHeight;
                    const tooManyIters = iterations >= maxIterations;
                    const tooTall = total >= maxScroll;
                    const tooLong = Date.now() - startedAt > maxElapsedMs;
                    if (reachedEnd || tooManyIters || tooTall || tooLong) {
                        clearInterval(timer);
                        window.scrollTo(0, 0);
                        resolve();
                    }
                }, 80);
            });
        }"""
    )


def apply_masks(page, selectors):
    if not selectors:
        return
    page.evaluate(
        """(sels) => {
            // Freeze all jarallax instances so they can't re-apply background-image
            // after we override it below.
            if (window.jarallax) {
                document.querySelectorAll('[data-jarallax],.jarallax').forEach(el => {
                    try { window.jarallax(el, 'destroy'); } catch (e) { console.warn('jarallax destroy failed on element:', e); }
                });
            }
            for (const sel of sels) {
                let elements;
                try {
                    elements = document.querySelectorAll(sel);
                } catch (e) {
                    console.warn(`Skipping invalid mask selector: ${sel}`, e);
                    continue;
                }
                elements.forEach(el => {
                    const rect = el.getBoundingClientRect();
                    if (!rect.width || !rect.height) return;
                    const overlay = document.createElement('div');
                    overlay.setAttribute('data-vr-mask', sel);
                    overlay.style.position = 'absolute';
                    overlay.style.left = `${rect.left + window.scrollX}px`;
                    overlay.style.top = `${rect.top + window.scrollY}px`;
                    overlay.style.width = `${rect.width}px`;
                    overlay.style.height = `${rect.height}px`;
                    overlay.style.background = '#cccccc';
                    overlay.style.zIndex = '2147483647';
                    overlay.style.pointerEvents = 'none';
                    el.style.visibility = 'hidden';
                    document.documentElement.appendChild(overlay);
                });
            }
        }""",
        selectors,
    )


def masks_for_path(masks_cfg, path):
    if not masks_cfg:
        return []
    # Strip query string for mask lookup so "/?flush=1" matches the "/" mask.
    bare = path.split("?", 1)[0] or "/"
    out = []
    for pattern, sels in masks_cfg.items():
        if pattern == "*" or pattern == bare:
            out.extend(sels)
            continue
        if pattern.endswith("/*"):
            # Match the prefix WITH the trailing slash so "/news/*" matches
            # "/news/", "/news/123" but not "/newsletter".
            prefix = pattern[:-1]  # keep the trailing slash
            if bare == prefix.rstrip("/") or bare.startswith(prefix):
                out.extend(sels)
    return out


def wait_for_fonts(page, timeout_ms=10000):
    """Await document.fonts.ready (CSS Font Loading API).

    Resolves when every @font-face declared on the page has either loaded
    or failed. Returns a list of font faces whose status is 'error' so the
    caller can surface real CDN/allowlist problems separately from the
    timing race this function exists to fix.
    """
    try:
        # Pass an explicit Playwright-level timeout (JS race + 2s buffer) so that
        # a crashed/unresponsive page context can't hang beyond the intended cap.
        result = page.evaluate(
            """async (timeoutMs) => {
                const deadline = new Promise((resolve) =>
                    setTimeout(() => resolve('timeout'), timeoutMs)
                );
                const raceResult = await Promise.race([document.fonts.ready, deadline]);
                if (raceResult === 'timeout') {
                    return 'timeout';
                }
                const errors = [];
                document.fonts.forEach((f) => {
                    if (f.status === 'error') {
                        errors.push({
                            family: f.family,
                            style: f.style,
                            weight: f.weight,
                            unicodeRange: f.unicodeRange,
                        });
                    }
                });
                return errors;
            }""",
            timeout_ms,
            timeout=timeout_ms + 2000,
        )
        if result == 'timeout':
            print(f"  [font-wait] timed out after {timeout_ms}ms — fonts.ready did not resolve", file=sys.stderr, flush=True)
            return []
        return result
    except Exception as e:
        print(f"  [font-wait] evaluation error (fonts.ready unavailable): {e}", file=sys.stderr, flush=True)
        return []


def capture_env(label, base_url, paths, out_dir, viewport, wait, auth, cookies, masks_cfg, insecure, wait_until, settle, block_urls):
    out_dir.mkdir(parents=True, exist_ok=True)
    results = []
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        ctx_kwargs = {
            "viewport": viewport,
            "ignore_https_errors": insecure,
            "device_scale_factor": 1,
        }
        if auth:
            user, _, pw = auth.partition(":")
            ctx_kwargs["http_credentials"] = {"username": user, "password": pw}
        context = browser.new_context(**ctx_kwargs)
        if cookies:
            context.add_cookies(cookies)
        if block_urls:
            import re as _re
            # Anchor each pattern at a domain/path boundary so "termly.io/..."
            # doesn't also match "nottermly.io/...".  Each user pattern must be
            # preceded by start-of-string, ".", or "/" in the full URL.
            # Explicit non-empty filter: re.escape("") produces an empty term
            # that would make (?:^|[./]) match any position in the URL.
            valid_patterns = [p for p in block_urls if p.strip()]
            combined = "|".join(
                r"(?:(?:^|[./])" + _re.escape(p) + ")"
                for p in valid_patterns
            )
            try:
                _block_re = _re.compile(combined, _re.IGNORECASE)
            except _re.error as exc:
                print(f"  [block-urls] invalid pattern — skipping URL blocking: {exc}", file=sys.stderr, flush=True)
                _block_re = None

            if _block_re:
                def _block(route):
                    route.abort()

                context.route(_block_re, _block)

        for path in paths:
            slug = slugify(path)
            out_path = out_dir / f"{slug}.png"
            url = base_url.rstrip("/") + path
            print(f"[{label}] {path} → {out_path.name}", flush=True)
            entry = {"path": path, "slug": slug, "url": url, "file": out_path.name}
            page = context.new_page()
            try:
                response = page.goto(url, wait_until=wait_until, timeout=45000)
                status = response.status if response is not None else None
                entry["http_status"] = status
                auto_scroll(page)
                page.wait_for_timeout(int(wait * 1000))
                font_errors = wait_for_fonts(page, timeout_ms=10000)
                if font_errors:
                    # Cap at 20 entries so a page with many failing fonts doesn't
                    # bloat manifest.json; a count field shows how many were truncated.
                    entry["font_errors"] = font_errors[:20]
                    if len(font_errors) > 20:
                        entry["font_errors_truncated"] = len(font_errors) - 20
                if settle == "networkidle":
                    try:
                        page.wait_for_load_state("networkidle", timeout=10000)
                    except Exception as e:
                        entry["settle_warning"] = f"networkidle timeout: {e}"
                apply_masks(page, masks_for_path(masks_cfg, path))
                page.screenshot(path=str(out_path), full_page=True)
                if status is not None and status >= 400:
                    # Still saved the screenshot for inspection, but flag
                    # the entry so the diff report classifies it as ERROR
                    # rather than silently passing matched 404/500 pages.
                    entry["ok"] = False
                    entry["error"] = f"HTTP {status}"
                    print(f"  [{label}] HTTP {status} — flagged", flush=True)
                else:
                    entry["ok"] = True
            except Exception as e:
                entry["ok"] = False
                entry["error"] = str(e)
                print(f"  [{label}] ERROR: {e}", flush=True)
            finally:
                page.close()
            results.append(entry)
        context.close()
        browser.close()
    return results


def main():
    ap = argparse.ArgumentParser(description="Capture full-page screenshots of two environments.")
    ap.add_argument("--prod", required=True, help="Production base URL")
    ap.add_argument("--local", required=True, help="Upgraded/UAT base URL")
    paths_group = ap.add_mutually_exclusive_group(required=True)
    paths_group.add_argument(
        "--paths",
        help="Comma-separated paths (e.g. /,/about,/contact). "
             "Avoid if any path contains a literal comma — use --paths-file instead.",
    )
    paths_group.add_argument(
        "--paths-file",
        metavar="FILE",
        help="Newline-delimited file of paths (e.g. paths.txt produced by crawl_urls.py). "
             "Preferred over --paths — handles paths that contain commas or query strings.",
    )
    ap.add_argument("--out", required=True, help="Output directory")
    ap.add_argument("--viewport", type=parse_viewport, default=parse_viewport("1440x900"))
    ap.add_argument(
        "--wait-until",
        choices=("load", "domcontentloaded", "networkidle", "commit"),
        default="load",
        help="Playwright navigation wait condition (default: load). Use networkidle for fully-static sites; load is safer on sites with analytics/chat/polling.",
    )
    ap.add_argument("--wait", type=float, default=2.0, help="Extra wait seconds after navigation completes")
    ap.add_argument(
        "--settle",
        choices=("load", "networkidle"),
        default="load",
        help=(
            "Pre-screenshot settle strategy (default: load). "
            "'load' awaits document.fonts.ready only. "
            "'networkidle' additionally waits for the network to be idle — "
            "recommended for sites with Termly/HubSpot/Hotjar that inject iframes asynchronously."
        ),
    )
    auth_help = (
        "HTTP basic auth. Accepts: 'user:pass' (visible in argv — discouraged), "
        "'env:VARNAME' (read user:pass from one env var), "
        "'env:USERVAR/PASSVAR' (split across two env vars), "
        "or 'prompt' for an interactive prompt."
    )
    ap.add_argument("--auth", help=f"Applied to both environments unless overridden. {auth_help}")
    ap.add_argument("--prod-auth", help=f"Overrides --auth for the production environment only. {auth_help}")
    ap.add_argument("--local-auth", help=f"Overrides --auth for the local/UAT environment only. {auth_help}")
    ap.add_argument("--cookies", help="Path to Playwright-format cookies JSON, applied to both environments unless overridden.")
    ap.add_argument("--prod-cookies", help="Path to Playwright-format cookies JSON for production only. Overrides --cookies.")
    ap.add_argument("--local-cookies", help="Path to Playwright-format cookies JSON for local/UAT only. Overrides --cookies.")
    ap.add_argument("--mask", help='Path to masks.json: {"/path": ["selector", ...]}')
    ap.add_argument("--insecure", action="store_true", help="Ignore HTTPS errors (self-signed certs)")
    ap.add_argument(
        "--block-urls",
        help=(
            "Comma-separated URL substrings to block on both sides via Playwright route interception. "
            "Useful for consent-management scripts (e.g. 'termly.io/resource-blocker') that run on prod "
            "but not locally and block first-party content before cookie consent is granted."
        ),
    )
    args = ap.parse_args()

    if args.paths_file:
        raw = Path(args.paths_file).read_text().splitlines()
        paths = [p.strip() for p in raw if p.strip() and not p.startswith("#")]
    else:
        paths = [p.strip() for p in args.paths.split(",") if p.strip()]
    if not paths:
        sys.exit("--paths / --paths-file produced no entries")
    paths = [p if p.startswith("/") else "/" + p for p in paths]

    out = Path(args.out)
    cookies = load_json(args.cookies) if args.cookies else None
    masks_cfg = load_json(args.mask) if args.mask else None
    resolved_auth = resolve_auth(args.auth)
    block_urls = [u.strip() for u in args.block_urls.split(",") if u.strip()] if args.block_urls else []

    # Per-env auth/cookies take precedence over the shared --auth/--cookies flags.
    # This prevents UAT credentials being sent to production when only UAT is protected.
    prod_auth = resolve_auth(args.prod_auth) if args.prod_auth else resolved_auth
    local_auth = resolve_auth(args.local_auth) if args.local_auth else resolved_auth
    prod_cookies = load_json(args.prod_cookies) if args.prod_cookies else cookies
    local_cookies = load_json(args.local_cookies) if args.local_cookies else cookies

    started = datetime.now(timezone.utc).isoformat()
    prod_results = capture_env(
        "prod", args.prod, paths, out / "prod",
        args.viewport, args.wait, prod_auth, prod_cookies, masks_cfg, args.insecure, args.wait_until, args.settle, block_urls,
    )
    local_results = capture_env(
        "local", args.local, paths, out / "local",
        args.viewport, args.wait, local_auth, local_cookies, masks_cfg, args.insecure, args.wait_until, args.settle, block_urls,
    )
    finished = datetime.now(timezone.utc).isoformat()

    manifest = {
        "prod_base": args.prod,
        "local_base": args.local,
        "viewport": args.viewport,
        "wait": args.wait,
        "wait_until": args.wait_until,
        "settle": args.settle,
        "block_urls": block_urls,
        "started": started,
        "finished": finished,
        "paths": paths,
        "prod": prod_results,
        "local": local_results,
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2))
    print(f"\nWrote manifest: {out / 'manifest.json'}")
    print(f"Captured {len(paths)} paths × 2 envs.")


if __name__ == "__main__":
    main()
