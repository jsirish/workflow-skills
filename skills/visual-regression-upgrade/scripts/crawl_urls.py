#!/usr/bin/env python3
"""Discover URLs on a site via sitemap.xml or a shallow link crawl.

Usage:
    crawl_urls.py --url https://www.example.com --limit 30 --out paths.txt
"""
import argparse
import html
import re
import sys
from collections import deque
from html.parser import HTMLParser
from urllib.parse import urljoin, urlparse

import requests


def _extract_locs(xml_text):
    """Extract <loc> values from sitemap XML, decoding XML entities."""
    raw = re.findall(r"<loc>\s*([^<\s]+)\s*</loc>", xml_text, re.IGNORECASE)
    return [html.unescape(u) for u in raw]


HEADERS = {"User-Agent": "vr-upgrade-crawler/1.0"}


def _fetch_sitemap_xml(url):
    """Fetch a sitemap XML. Returns (text, final_url) or (None, None)."""
    try:
        r = requests.get(url, headers=HEADERS, timeout=15)
        if r.status_code != 200 or "<loc>" not in r.text.lower():
            return None, None
        return r.text, r.url
    except requests.RequestException:
        return None, None


def _hosts_match(a, b):
    """Treat foo.com and www.foo.com as the same host."""
    def norm(h):
        return (h or "").lower().lstrip(".").removeprefix("www.")
    return norm(a) == norm(b)


def _is_sitemap_index(xml_text):
    return "<sitemapindex" in xml_text.lower()


def _collect_page_urls(xml_text, base_host, max_indexes=10):
    """Return page URLs from sitemap XML, recursing into sitemap indexes."""
    locs = _extract_locs(xml_text)
    if _is_sitemap_index(xml_text):
        page_urls = []
        for sub in locs[:max_indexes]:
            pu = urlparse(sub)
            if pu.netloc and not _hosts_match(pu.netloc, base_host):
                continue
            sub_xml, _ = _fetch_sitemap_xml(sub)
            if not sub_xml:
                continue
            # Only recurse one level deep — sitemap indexes pointing to
            # sitemap indexes are rare and not worth the complexity.
            if _is_sitemap_index(sub_xml):
                continue
            page_urls.extend(_extract_locs(sub_xml))
        return page_urls
    return locs


def try_sitemap(base_url, limit):
    sitemap_url = base_url.rstrip("/") + "/sitemap.xml"
    xml_text, final_url = _fetch_sitemap_xml(sitemap_url)
    if not xml_text:
        return None
    # Honour redirects: if example.com → www.example.com, sitemap <loc>
    # entries will use the canonical host. Treat that as the base host
    # so we don't filter out our own pages.
    resolved_host = urlparse(final_url).netloc if final_url else urlparse(base_url).netloc
    paths = []
    seen = set()
    for u in _collect_page_urls(xml_text, resolved_host):
        pu = urlparse(u)
        if pu.netloc and not _hosts_match(pu.netloc, resolved_host):
            continue
        # Skip anything that still looks like a sitemap rather than a page.
        if pu.path.endswith((".xml", ".xml.gz")):
            continue
        path = pu.path or "/"
        if pu.query:
            path += "?" + pu.query
        if path in seen:
            continue
        seen.add(path)
        paths.append(path)
        if len(paths) >= limit:
            break
    return sorted(paths) if paths else None


class LinkParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []

    def handle_starttag(self, tag, attrs):
        if tag.lower() != "a":
            return
        for k, v in attrs:
            if k.lower() == "href" and v:
                self.links.append(v)


def crawl(base_url, limit, max_depth=2):
    # Follow the initial redirect (if any) so the canonical host becomes
    # the comparison base — otherwise a site that redirects bare→www
    # would have every same-site link filtered out.
    # If the redirect lands on a different host (e.g. an external holding
    # page), keep the original URL as the base to avoid fetching off-scope
    # content as if it were part of the site.
    original_host = urlparse(base_url).netloc
    try:
        initial = requests.get(base_url, headers=HEADERS, timeout=15)
        initial_host = urlparse(initial.url).netloc
        if _hosts_match(initial_host, original_host):
            resolved_url = initial.url
            initial_html = (
                initial.text
                if initial.status_code == 200 and "text/html" in initial.headers.get("content-type", "").lower()
                else None
            )
        else:
            resolved_url = base_url
            initial_html = None
    except requests.RequestException:
        resolved_url = base_url
        initial_html = None

    base_host = urlparse(resolved_url).netloc
    seen_paths = set()
    queue = deque([(resolved_url, 0, initial_html)])
    visited_urls = set()
    paths = []

    while queue and len(paths) < limit:
        url, depth, prefetched_html = queue.popleft()
        if url in visited_urls:
            continue
        visited_urls.add(url)
        body = prefetched_html
        if body is None:
            try:
                r = requests.get(url, headers=HEADERS, timeout=15)
                final_url = r.url
                if not _hosts_match(urlparse(final_url).netloc, base_host):
                    continue
                if r.status_code != 200 or "text/html" not in r.headers.get("content-type", "").lower():
                    continue
                url = final_url
                body = r.text
            except requests.RequestException:
                continue

        pu = urlparse(url)
        path = pu.path or "/"
        if _hosts_match(pu.netloc, base_host) and path not in seen_paths:
            seen_paths.add(path)
            paths.append(path)

        if depth >= max_depth:
            continue
        parser = LinkParser()
        try:
            parser.feed(body)
        except Exception:
            continue
        for href in parser.links:
            if href.startswith(("#", "mailto:", "tel:", "javascript:")):
                continue
            absolute = urljoin(url, href)
            pa = urlparse(absolute)
            if not _hosts_match(pa.netloc, base_host):
                continue
            # strip fragment and query for crawl frontier; preserve path
            clean = pa._replace(fragment="", query="").geturl()
            if clean not in visited_urls:
                queue.append((clean, depth + 1, None))

    return sorted(set(paths))[:limit]


def main():
    ap = argparse.ArgumentParser(description="Discover URLs via sitemap.xml or shallow crawl.")
    ap.add_argument("--url", required=True, help="Base URL (e.g. https://www.example.com)")
    ap.add_argument("--limit", type=int, default=30, help="Max paths to return")
    ap.add_argument("--out", default="paths.txt", help="Output file (one path per line)")
    args = ap.parse_args()

    base = args.url.rstrip("/")
    print(f"Trying sitemap: {base}/sitemap.xml", flush=True)
    paths = try_sitemap(base, args.limit)
    if paths:
        print(f"  → sitemap returned {len(paths)} paths", flush=True)
    else:
        print("  → no sitemap; falling back to depth-2 crawl", flush=True)
        paths = crawl(base, args.limit)
        print(f"  → crawl returned {len(paths)} paths", flush=True)

    if not paths:
        sys.exit("No paths discovered.")

    with open(args.out, "w") as f:
        for p in paths:
            f.write(p + "\n")
    print(f"Wrote {len(paths)} paths to {args.out}")


if __name__ == "__main__":
    main()
