# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

----

## [Unreleased]

### Added

- `seedUrls` argument on `SitemapService.create()`: an array of extra start URLs
  for orphan pages that no reachable page links to. They are crawled alongside
  `url`; the host, `robots.txt` base, and split-file base URL still come from the
  first `url`, so all seeds must share its host.
- `ignored` key in the crawl result: an array of `{ url, reason }` structs for
  links the crawl dropped, so you can see what was skipped and why. Reasons are
  `"nofollow"` (a `rel="nofollow"` link), `"excluded"` (matched `excludeUrls` or
  `excludePattern`), and `"disallowed"` (blocked by `robots.txt`). The existing
  `disallowedUrls` array is unchanged; robots-blocked URLs appear in both.
- `excludePattern` module setting: a regex matched case-insensitively against the
  full URL for whole-section excludes (e.g. `/admin/`). A match skips the URL and
  reports it in `ignored` with reason `"excluded"`. This is separate from the
  per-crawl exact-URL `excludeUrls` argument. Defaults to empty (no pattern
  exclusion).

### Changed

- `Parser.getLinks()` now returns a struct `{ links, ignored }` instead of a
  plain array of link strings. `links` is the same crawlable-URL array as before;
  `ignored` lists the page's `rel="nofollow"` drops as `{ url, reason }`.
- `respectRobotsTxt` still defaults to `true`. Most users crawl their own site
  and may prefer to ignore `robots.txt`; set `respectRobotsTxt = false` in the
  module settings to do so.

----

## [1.0.0] - 2026-07-21

First stable release. The module crawls a site breadth-first from one or more
start URLs and generates a sitemaps.org XML sitemap.

### Added

- Breadth-first crawler with configurable `maxDepth` and `maxPages`.
- `robots.txt` support: fetches and honors `Disallow` / `Allow` rules, selects
  the matching `User-agent` group, and applies `Crawl-delay` up to `maxCrawlDelay`.
- Redirect handling for HTTP redirects and `<meta>` refresh, with the final URL
  recorded once.
- Configurable browser backend selected by the `browserDsl` setting: jsoup
  (default, static HTML) or cbPlaywright (`Playwright@sitemap-spider`) for
  JavaScript-rendered pages, with `waitStrategy` / `waitMs` controls.
- W3C `<lastmod>` output (date-only), with a `lastModFallback` setting to omit
  the element or use the crawl time when a page has no Last-Modified.
- Save-to-file via `create( ..., filePath = )`, creating the directory as needed
  and throwing `sitemap-spider.SaveFailed` on a write error.
- Sitemap index splitting: when a crawl exceeds `maxUrlsPerSitemap` (50000) or
  `maxSitemapBytes` (50 MiB), the output becomes a `<sitemapindex>` plus numbered
  child `<urlset>` files, with an optional `publicBaseUrl` for the index entries.
- Unit, integration, and contract test coverage under `test-harness`.

### Changed

- Consolidated the fetch layer behind the `IBrowser` interface and removed the
  old `cfhttp` backend (jsoup covers static fetching).
- Refactored the crawler to synchronous-only for v1, with O(1) struct lookups
  replacing the previous O(n) scans. Async crawling is planned for a later
  release.

### Fixed

- Removed leftover `writeDump` debug output that corrupted responses and test runs.
- Corrected the URL filter's inverted `reMatch` arguments.
- Reset crawler state at the start of each crawl so a reused (cached) instance no
  longer carries pages over from a previous crawl.
