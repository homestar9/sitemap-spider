# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
