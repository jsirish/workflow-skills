# SilverStripe-specific gotchas

Tips for using this skill against SilverStripe sites, especially during major-version upgrades (SS3→4, SS4→5).

## Cache busting

- **Always append `?flush=1` to the first request on each environment.** SilverStripe caches templates, the class manifest, and config in `silverstripe-cache/`. Stale cache after an upgrade is the #1 cause of "blank page" or "old layout" screenshots.
- If you keep seeing the wrong template render, also try `?flush=all` and confirm the dev/build was run on UAT.
- Leftover `silverstripe-cache/` directories from SS4 can poison an SS5 boot. `rm -rf silverstripe-cache/ && ?flush=1` clears the slate.

## Stage vs Live

- **Always compare Live → Live.** SilverStripe has two content stages (`Stage` = draft, `Live` = published). The `?stage=Stage` querystring switches.
- Comparing prod-Live against UAT-Stage will show *content* diffs that are not regressions — they're just unpublished edits.
- If the upgrade target is locked to a content snapshot, dump the DB from prod and re-import on UAT before capturing, so both sides have identical content.

## Auth paths

- `/admin`, `/Security/login`, `/dev/build` need authentication.
- **HTTP basic auth** at the web-server level (often used to gate UAT) → use `--auth user:pass`.
- **CMS login** (form-based) → log in via a real browser, export cookies, save as `cookies.json`, pass `--cookies cookies.json`.
- The CMS admin is rarely worth screenshot-diffing; exclude it from `paths.txt` unless you're explicitly testing the CMS UI.

## SS4 → SS5 common visual regressions

| Area | What changes | Mask / fix |
|------|--------------|------------|
| Bootstrap 3 → 4 grid | `.col-xs-*` deprecated → `.col-*`. Theme templates using xs classes silently lose styling. | Inspect WARN pages; usually a real layout regression to fix in templates. |
| Elemental content blocks | Block ordering may shift if `Sort` field semantics changed in an extension. | Diff page-by-page; not a mask candidate. |
| `SiteConfig` fields | Some fields removed in SS5 (e.g. `Tagline`). Header/footer templates referencing them render blank. | Real regression — patch templates. |
| `default.ss` template | Default scaffolding changed between SS4/5. Custom themes overriding it usually unaffected; non-themed pages may differ. | Real regression. |
| `$Layout` placement | Subtle whitespace changes in default templates. | Likely WARN; can ignore if structure is intact. |
| `UserDefinedForm` submissions | Renders inside a `<div class="userform">` wrapper in SS5; SS4 wrapped in `<form>` directly. | Real regression — usually CSS-fixable. |

## Asset/image differences

- If UAT shows broken images:
  - `assets/Uploads/` may not be symlinked or copied to UAT
  - SS4+ uses **protected assets**: `assets/.protected/` holds originals, public `_resources/` is published. Ensure both are present.
  - Run `dev/tasks/MigrateFileTask` on UAT after the upgrade, or images stay in legacy paths.
- If thumbnails are wrong sizes: re-publish images (`File::publishSingle()` via a task) or run `?flush=1`.

## Fonts and external resources

- Google Fonts often **don't load on UAT** due to outbound firewall rules. Result: serif fallback everywhere, ~10–30% diff on every text-heavy page.
- Mask the affected regions or, better, host the fonts locally on both sides before comparing.
- Same applies to Typekit, FontAwesome via CDN, and any other CDN-loaded asset.

## Dynamic content to mask

Common SilverStripe widgets that change between captures:

```json
{
  "*": [
    ".cookie-notice",
    "#cookieNotice",
    ".carousel-inner",
    ".rotating-banner",
    "[data-rotating]",
    ".current-date",
    ".live-visitor-count",
    "iframe[src*='youtube']",
    "iframe[src*='vimeo']"
  ]
}
```

### SS4 dev environment — one-sided elements

Some elements only exist on the **local/UAT** side and have no counterpart on prod. The default mask (gray background) doesn't fully suppress these — it makes the element gray on the local side but prod still has nothing there, so a small residual diff remains.

**Mitigation:** accept the residual diff as noise (usually < 1% for small dev bars). Masks suppress the element's content where it exists, but they cannot create a matching grey box on the side where the element is absent — so a small positional diff remains. For a clean zero-diff, remove the element entirely on the UAT side (e.g. disable the module) before capturing.

Common one-sided elements to include in `"*"` masks:

| Selector | What it is | Notes |
|----------|-----------|-------|
| `#BetterNavigator` | SS4 Better Navigator dev bar | `position: fixed`, collapsed ~35×82px, right side at 110px top. Harmless residual diff. |
| `#debugbar`, `.debugbar`, `[id^="debugbar"]` | lekoala/silverstripe-debugbar | Full-width bar at bottom. Only installed on dev. |
| `#silverstripemessages` | SS flash messages bar | Appears after login; rarely in screenshots. |
| `.message.notice` | SS4 site-wide notice banners | If shown, appears at top of `<main>`. |

**Complete SS4 local-vs-prod mask template:**

```json
{
  "*": [
    "#BetterNavigator",
    "#debugbar",
    "[id^='debugbar']",
    ".staffmember-image",
    ".cookie-notice",
    "#cookieNotice",
    "iframe[src*='youtube']",
    "iframe[src*='vimeo']"
  ],
  "/": [
    ".flexslider",
    ".recentblogpostsblock",
    ".upcomingeventsblock"
  ]
}
```

### Custom Elemental elements (project-specific)

For projects using the `dynamic/example-custom` PageSection element pattern, also mask:

```json
{
  "*": [".pagesection__image"]
}
```

This grays out the image portion of two-column PageSection blocks while preserving the column layout structure in the diff. Useful when image content changes frequently on prod between syncs.

### Why FAILs persist after masking

If masked pages still show 5–15% FAIL, the remaining diff is almost always **text content drift** — editors updated copy, statistics, or dates on prod since the last DB sync. This is expected and does not indicate a structural regression. Remedies:

1. **Re-sync prod DB** immediately before capturing — removes content drift entirely.
2. **Accept the threshold** — bump `diff_pct` FAIL threshold to 15% when content-only drift is known.
3. **Mask text-heavy blocks** — add selectors for specific blocks (`[class*="typography"]`, `.main-content`) if you want a pure-layout diff. Not recommended for ongoing regression detection.

## SS_BASE_URL traps

- If `SS_BASE_URL` is set on UAT but the site URL differs, `$AbsoluteLink` returns links pointing at the wrong host. Visual diff stays clean but real users land elsewhere.
- Not a screenshot issue — but worth `curl`-checking the canonical `<link rel="canonical">` and `og:url` tags on a few pages before signing off.

## Recommended exclusions for upgrade diff

Drop these from `paths.txt` before capturing — they're noisy without being load-bearing:

- `/Security/*` (login forms)
- `/admin/*` (CMS, unless explicitly under test)
- `/sitemap.xml`, `/robots.txt`
- Paginated archives beyond page 1 (`?start=`)
- Search results (`/search?q=…`)

## Sanity check before signing off

After a clean PASS report, spot-check 2-3 pages manually in both browsers to confirm the report isn't misleadingly green because of:
- Both screenshots being identically blank (JS failed on both)
- Both being identically redirected to a maintenance page
- Identical cookie banners covering the actual content on both sides

The HTML report makes this easy: open it, scroll to a content-heavy page, eyeball the "All three" view.
