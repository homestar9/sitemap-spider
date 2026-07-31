# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

----

## [Unreleased]

## [1.1.0] - 2026-07-30

### Added

- A broken link report, saved as JSON beside the sitemap. A crawl already visits
  every page, so it already knows which links are dead; the report saves that
  instead of discarding it. `writeLinkReport` (setting and per-crawl argument,
  default off) writes `broken`, `redirects`, and `skipped` lists plus a `summary`
  of counts. The new `linkReportPath` setting supplies a private default
  location; when empty, `<filePath minus .gz>.links.json` is written beside the
  sitemap, following the same rules as the metadata sidecar. Read it back with
  `SitemapService.readLinkReport( path )`, which accepts either path and returns
  `{ exists : false }` when the file is missing or unreadable. A failed write
  throws the typed `sitemap-spider.LinkReportSaveFailed`. The result struct
  gained `linkReportPath` and `linkReportSaved`; `queue()` passes both arguments
  through, stores them on the job record, and returns them in `result`.
  Reporting broken pages costs no extra HTTP requests.
- `models/LinkReportGenerator.cfc`, a stateless singleton that turns a crawl
  result into the report struct. It sorts `broken` with server errors first,
  then missing pages, then transport failures, and marks a `redirects` entry
  `permanent` for a 301 or 308.
- Failure detail on every `badUrls` entry. Alongside the existing `message`,
  each entry now carries `status` (the HTTP status, or `0` when the request
  never got a response), `reason`, `kind` (`"page"` or `"asset"`),
  `redirectChain`, `foundOn`, and `foundOnTruncated`. `reason` is one of
  `notFound`, `serverError`, `clientError`, `redirectError`,
  `tooManyRedirects`, `timeout`, `connectionFailed`, or `unknown`. Previously a
  404, a 500, a timeout, and a redirect loop were indistinguishable without
  parsing English out of `message`.
- `foundOn` names the pages that link to a broken or redirected URL, which is
  what makes a report actionable. `trackInboundLinks` (default on) and
  `maxInboundLinks` (default 10) control it. Referrers are dropped as URLs are
  fetched successfully, so memory tracks the queue and the failures rather than
  every link on the site. A redirected URL keeps its referrers, because those
  are the links worth updating.
- `checkAssets` setting (default off) requests the status of on-host images,
  stylesheets, scripts, and links to files that `notAllowedPattern` blocks —
  broken images were previously invisible. Checks run after the page crawl, so
  each unique asset is requested once no matter how many pages use it. They use
  `HEAD`, falling back to a one-byte `GET` on a 405 or 501, never enter `pages`
  or `maxPages` or the sitemap XML, and ignore off-host URLs. `maxAssetChecks`
  (default 5000) caps them. This is the only part of the report that makes extra
  requests.
- `stats` gained `assetsCheckedCount` and `assetsBrokenCount`. The crawl result
  gained `assetsChecked`.
- `redirects` entries gained `status` (the first hop's status), `foundOn`, and
  `foundOnTruncated`.

### Changed

- **Breaking for custom browser backends.** `IBrowser` now requires
  `checkUrl( url )`, which returns `{ ok, status, url, redirectChain, error }`
  and must never throw. A backend extending `BaseBrowser` inherits a working
  implementation that asks the jsoup backend for the status, so no change is
  needed there. A backend implementing `IBrowser` directly must add the method.
- `fetchUrl()` implementations should now set `errorCode` (the HTTP status) and
  `extendedInfo` (JSON with `status`, `url`, and `chain`) on a thrown
  `StatusCodeException`. Both bundled backends do. A backend that omits them
  still crawls correctly; its failures report `status: 0` and
  `reason: "unknown"`.
- `Parser.getLinks()` returns a third array, `assets`: on-host links rejected
  only by `notAllowedPattern`. Off-host links are still dropped. Added
  `Parser.getAssetLinks()` for embedded images, stylesheets, and scripts, and
  `Parser.isSameHost()`, which `isUrlAllowed()` now builds on.
- The Playwright backend now builds its redirect chain before checking the
  status, so a failed navigation reports the hops that led to it.

----

## [1.0.0] - 2026-07-30

First stable release. The module crawls a site breadth-first from one or more
start URLs and generates a sitemaps.org XML sitemap.

### Added

- A pre-computed `stats` struct on the `create()` result and on completed job
  records (`result.stats`): `generatedAt` (ISO-8601 with UTC offset),
  `durationMs`, `urlCount`, `sitemapCount`, `type`, `badUrlCount`,
  `ignoredCount`, and `redirectCount`. Saves every caller from deriving counts
  out of the raw `pages` / `badUrls` / `ignored` / `redirects` collections.
- A JSON metadata "sidecar" file, for admin screens that show "last generated"
  stats without keeping job records. `writeMetadata` (setting and per-crawl
  argument, default off) writes the stats struct, crawl options, and module
  version. The new module-wide `metadataPath` setting supplies a private default
  location; when empty, `<filePath minus .gz>.meta.json` is written beside the
  sitemap. A non-empty per-crawl argument overrides the setting, while an
  explicitly empty argument forces adjacent-file derivation. This distinction
  is snapshotted on queued jobs. Move the sidecar outside the webroot before
  enabling `metadataIncludeUrls`, which adds the full `badUrls` and `ignored`
  lists. Read it back with the new `SitemapService.readMetadata( path )`, which
  accepts the sitemap path or the sidecar path and returns `{ exists : false }`
  instead of throwing when the file is missing or unreadable. A sitemap path
  honors the module setting; an explicit sidecar path is read literally. A
  failed sidecar write throws the typed `sitemap-spider.MetadataSaveFailed`.
  The result struct gained `metadataPath` and `metadataSaved` keys; `queue()`
  passes all three arguments through and stores them on the job record.
- `respectNoIndex` setting (default `true`). A page carrying
  `<meta name="robots" content="noindex">` (or `none`) or an
  `X-Robots-Tag: noindex` response header is left out of the sitemap and
  reported in `ignored` with the new reason `"noindex"`. Its links are still
  followed, because `noindex` does not mean `nofollow`. An agent-scoped header
  directive (`googlebot: noindex`) counts as global on purpose. Set the flag
  to `false` to list such pages anyway.

- JSON-LD videos. `includeVideos` now reads schema.org `VideoObject` entries out
  of `<script type="application/ld+json">` blocks, on top of the Open Graph tags
  and `<video>` elements it already read. Entries are found wherever they sit in
  the block: at the top level, in an array, under `@graph`, or nested inside
  another type. `contentUrl` becomes `<video:content_loc>`, `embedUrl` becomes
  `<video:player_loc>`, and the block's own `name`, `description` and
  `thumbnailUrl` are used instead of the page-level fallbacks. A block that is
  not valid JSON is skipped and the crawl carries on. JSON-LD is read before the
  other two sources, so when two of them name the same URL the JSON-LD entry is
  the one that survives.
- `<video:duration>`, converted from the JSON-LD `duration` field's ISO 8601
  form (`PT1M33S`) to the whole seconds the sitemap protocol wants. Video structs
  on the crawl result gained a matching `duration` key. A value that cannot be
  read, or that falls outside Google's 1–28800 second range, is left out.
- `includeImages`, `includeHreflang` and `includeVideos` arguments on
  `SitemapService.create()`, `Crawler.crawl()` and `SitemapJobRegistry.queue()`.
  Each overrides the module setting of the same name for one crawl, in either
  direction; omitting the argument uses the setting. A host generating sitemaps
  for many sites needs this, because the right extensions differ per site. Job
  records gained `includeImages`, `includeHreflang` and `includeVideos` keys; a
  record written before they existed still runs, falling back to the settings.
- Background sitemap jobs, so a host app can crawl several sites at once, watch
  each one's progress, and cancel one. `SitemapJobRegistry@sitemap-spider`
  provides `queue()` (returns a job id right away), `getJob()`, `listJobs()`,
  `cancel()`, and `remove()`. `maxConcurrentJobs` (default `3`) sets how many run
  at once; the rest wait as `queued` and start as slots free up. A queued job
  must be given a `filePath`, because a background job has no response to write
  to. Calling `SitemapService.create()` directly is unchanged and still blocks.
- Live crawl progress and cancellation. `SitemapService.create()` and
  `Crawler.crawl()` take an optional `progress` argument (a `CrawlProgress`)
  reporting pages found, URLs processed, bad URLs, how many are left, and elapsed
  time. Cancelling it stops the crawl after the page it is on. Omitting the
  argument leaves behavior exactly as before.
- `browserDsl` argument on `SitemapService.create()`, `Crawler.crawl()`, and
  `SitemapJobRegistry.queue()`, choosing the browser backend for one crawl. Empty
  uses the `browserDsl` setting. This is for hosts crawling many sites where only
  some need JavaScript rendering.
- Pluggable job storage. `IJobStore` defines where job records live, and
  `InMemoryJobStore` (the default) keeps them in memory. Point the new
  `jobStoreDsl` setting at your own implementation to keep records across
  restarts or to share them between app servers. The counters that change during
  a crawl never reach the store — it only sees status changes and a periodic
  heartbeat.
- Recovery for jobs that stop unexpectedly, so none are left looking like they
  are still running. A ColdBox reinit cancels running crawls and records them as
  `interrupted`; a background task marks jobs that stop reporting progress
  (`jobStaleSeconds`); and with a durable store, jobs left running by a previous
  start of the app are marked at startup. The upkeep ships with the module in
  `config/Scheduler.cfc` and needs no wiring. New settings: `jobNodeId`,
  `jobHeartbeatSeconds`, `jobStaleSeconds`, `jobReaperEnabled`,
  `jobReaperIntervalSeconds`, `maxRetainedJobs`.
- Job events a host app can listen to: `onSitemapJobQueued`,
  `onSitemapJobStarted`, `onSitemapJobCompleted`, `onSitemapJobFailed`, and
  `onSitemapJobInterrupted`, each with `{ jobId, record }`. Use them to upload the
  finished file, notify someone, or decide whether to retry. Announcing an event
  nobody listens for does nothing.
- `meta` argument on `SitemapJobRegistry.queue()`: a struct of the host's own
  values (site id, customer id, and so on) stored with the job, returned on every
  read, and usable as a filter in `listJobs()`. This module never reads it.
- `gzipOutput` module setting: when `true` and a `filePath` is given, the sitemap
  files are written gzip-compressed with a `.gz` suffix (e.g. `sitemap.xml.gz`).
  For a split set the child filenames and the `<sitemapindex>` `<loc>` entries
  carry `.gz` too, and `result.filePath` reports the `.gz` path. Defaults to
  `false` (plain XML).
- `lastModFormat` module setting: `"date"` (default) writes the date-only
  `<lastmod>` (`YYYY-MM-DD`); `"datetime"` writes the full W3C timestamp
  (`YYYY-MM-DDThh:mm:ss+HH:MM`) in the server's local timezone.
- `includeImages` module setting: when `true`, each crawled page's `<img src>`
  images are collected and emitted as `<image:image>` entries, and the
  `<urlset>` gains the image namespace. Images are not host-filtered (CDN images
  are kept), and each page's `images` array is included in the crawl result.
  Defaults to `false` (no image entries, output unchanged).
- `includeHreflang` module setting: when `true`, each crawled page's
  `<link rel="alternate" hreflang="...">` tags are collected and emitted as
  `<xhtml:link>` entries, and the `<urlset>` gains the xhtml namespace.
  Alternates are emitted exactly as the page declared them — off-host targets
  are kept and `x-default` is allowed — and each page's `alternates` array is
  included in the crawl result. Defaults to `false` (output unchanged).
- `includeVideos` module setting: when `true`, each crawled page's videos are
  collected and emitted as `<video:video>` blocks, and the `<urlset>` gains the
  video namespace. Videos are read from Open Graph tags (`og:video` becomes
  `<video:player_loc>`) and `<video>` elements (`src` or a `<source src>` child
  becomes `<video:content_loc>`, `poster` the thumbnail), with the page title,
  meta description, and `og:image` as fallbacks for the required fields. A video
  still missing a required field is dropped. Each page's `videos` array is
  included in the crawl result. Defaults to `false` (output unchanged).
- `seedUrls` argument on `SitemapService.create()`: an array of extra start URLs
  for orphan pages that no reachable page links to. They are crawled alongside
  `url`; the host, `robots.txt` base, and split-file base URL still come from the
  first `url`, so all seeds must share its host.
- `ignored` key in the crawl result: an array of `{ url, reason }` structs for
  URLs the crawl dropped, so you can see what was skipped and why. Reasons are
  `"nofollow"` (a `rel="nofollow"` link), `"excluded"` (matched `excludeUrls` or
  `excludePattern`), `"disallowed"` (blocked by `robots.txt`), and `"notAllowed"`
  (a rejected start/seed URL that is off-host, the wrong scheme, or an asset URL).
  A rejected start or seed URL is reported here too.
- `excludePattern` module setting: a regex matched case-insensitively against the
  full URL for whole-section excludes (e.g. `/admin/`). A match skips the URL and
  reports it in `ignored` with reason `"excluded"`. This is separate from the
  per-crawl exact-URL `excludeUrls` argument. Defaults to empty (no pattern
  exclusion).
- `excludePattern` argument on `SitemapService.create()`: the same section-exclude
  regex, per crawl. When passed non-empty it overrides the `excludePattern` module
  setting for that crawl only; empty falls back to the setting. Lets one crawl
  exclude a section without changing global config.
- `waitForSelector` module setting (Playwright backend): a CSS selector to wait
  for after navigation, so you can wait for a known JS-injected element instead
  of a large blanket `waitMs`. It returns as soon as the element appears (bounded
  by `requestTimeout`); a selector that never appears logs a warning and the
  fetch continues. Defaults to empty (disabled); combines with `waitMs`.
- `maxRedirects` module setting: the most HTTP redirect hops the Jsoup backend
  follows for one URL before recording it as bad. It now follows redirects itself
  so it can enforce this limit and report the hop chain. Defaults to `20`
  (matching jsoup's own cap, so normal sites are unaffected).
- `redirects` key in the crawl result: one `{ from, to, chain }` entry per fetched
  URL that followed an HTTP redirect. `from` is the requested URL, `to` is the
  final URL, and `chain` lists each hop as `{ url, status }`.
- Parallel crawling. `runAsync` (setting and per-crawl argument, default
  `false`) fetches URLs on `asyncMaxThreads` worker threads (default `10`) when
  the browser backend is parallel-safe. A `robots.txt` `Crawl-delay` is still
  honored by spacing fetches across the workers.
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

- **Breaking:** `IJobStore` gained an `isShared()` method. A custom job store
  must add `boolean function isShared()` or it will no longer instantiate.
  Return `false` for a store only one app server reaches, even a durable one;
  return `true` when several app servers read the same records. The answer
  decides whether the module's two background timer tasks run at all.
- The heartbeat and dead-job tasks now only apply to a store that reports
  `isShared()` as `true`, and when it does not they are never registered with the
  scheduler: the module asks the store once while it loads, and skips handing
  either task to the executor. Nothing is scheduled and no thread wakes on an
  interval. Neither task could achieve anything otherwise: a single server reads
  its own live counters straight out of memory rather than from the store, and
  the once-per-boot startup sweep already clears rows its own previous start
  left behind. With the default `InMemoryJobStore` the dead-job check could never
  have found anything at all, because a record only goes stale when the heartbeat
  task stops, and both tasks share one executor. So a default install now does no
  background work. The startup sweep still always runs, which is what a durable
  single-server store needs. Because the store is asked while the module loads,
  changing `jobStoreDsl` needs a reinit to take effect.
- Default `jobHeartbeatSeconds` is now `30` (was `15`), `jobStaleSeconds` `180`
  (was `90`), and `jobReaperIntervalSeconds` `120` (was `60`). A crawl runs for
  minutes, so the old intervals were tuned tighter than anything needed. These
  only apply to a shared store now.
- `jobReaperEnabled` is now a second off-switch on top of the store's own
  `isShared()` answer, rather than the only one. Setting it `false` still stops
  the dead-job task on a shared store; setting it `true` no longer switches that
  task on for an unshared store.
- License changed from MIT to the
  [PolyForm Perimeter License 1.0.1](https://polyformproject.org/licenses/perimeter/1.0.1).
  You can still use sitemap-spider in personal and commercial website projects,
  including client work, and you can still modify and redistribute it. You
  cannot use it to provide a competing sitemap generation product or hosted
  sitemap generation service. The license file is now `LICENSE.md` instead of
  `LICENSE`, and the readme has a section explaining the terms in plain English.
- `SitemapService.create()` now builds a fresh `Crawler` for each call instead of
  reusing one injected instance. A crawler keeps the whole crawl in its own
  variables scope, so two crawls running at the same time used to overwrite each
  other's state. Each crawl now gets its own crawler and its own browser. Single
  crawls behave exactly as before.
- A crawl now takes its own copy of the module settings when it starts. Settings
  are one shared struct, so without this a second crawl running at the same time,
  or a host changing a setting mid-crawl, could alter a crawl already underway.
  Changing a setting now affects crawls that start afterwards.

- `Parser.getLinks()` now returns a struct `{ links, ignored }` instead of a
  plain array of link strings. `links` is the same crawlable-URL array as before;
  `ignored` lists the page's `rel="nofollow"` drops as `{ url, reason }`.
- `respectRobotsTxt` still defaults to `true`. Most users crawl their own site
  and may prefer to ignore `robots.txt`; set `respectRobotsTxt = false` in the
  module settings to do so.
- A `robots.txt` `Crawl-delay` no longer forces a single-threaded crawl. A
  parallel crawl (`runAsync = true`) now honors the delay by spacing fetches
  `Crawl-delay` seconds apart across the workers, so a delayed site can still be
  crawled in parallel. A crawl still runs single-threaded only when the browser
  backend is not parallel-safe (e.g. Playwright).
- **Breaking:** the crawl result `pages` is now an **array** of page structs
  (each `{ url, lastModified, priority, depth, images }`), not a struct keyed by
  URL. A CFML struct's keys are case-insensitive, so keying pages by URL merged
  two URLs that differ only in path case (`/Page` vs `/page`) even though the
  crawl visits them separately; an array keeps them distinct. `SitemapGenerator`'s
  `generate()` and `generateSet()` now take `pages` as an array too.
- A rejected start or seed URL is now reported in `ignored` with its reason
  (`"excluded"`, `"disallowed"`, or the new `"notAllowed"`), instead of only being
  logged.
- Consolidated the fetch layer behind the `IBrowser` interface and removed the
  old `cfhttp` backend (jsoup covers static fetching).
- Refactored the crawler's bookkeeping to O(1) struct lookups, replacing the
  previous O(n) scans.

### Fixed

- Two stacktraces on every `?fwreinit=true`, reading
  `has no accessible Member with name [PROGRESSMAP]` or `[STORE]`. WireBox puts a
  singleton in its cache before wiring it, so that circular dependencies can
  resolve, which meant a scheduled task firing during a reinit could fetch a
  `SitemapJobRegistry` whose `onDiComplete()` had not run yet. Both timer tasks
  fired at once because neither had a startup delay. `SitemapJobRegistry` is now
  marked `threadsafe`, so WireBox only publishes it once wiring has finished;
  its background methods return `0` rather than throwing if they are somehow
  called earlier; and the timer tasks are staggered so neither starts during the
  reinit. It self-healed on the next tick before, but put two stacktraces in the
  log each time.
- A failing scheduled task logged a second, misleading stacktrace
  (`No matching function [ERR] found`) instead of the intended one-line message.
  The failure handlers in `config/Scheduler.cfc` called `err()`, and the startup
  and dead-job tasks called `out()`, but both belong to `ScheduledTask` rather
  than to a scheduler, so neither resolved. `out()` could never have worked at
  all, because ColdBox calls a task closure with no arguments. They now use the
  LogBox logger ColdBox injects into the scheduler as `log`. This affected every
  engine, not just Lucee.
- Removed leftover `writeDump` debug output that corrupted responses and test runs.
- Corrected the URL filter's inverted `reMatch` arguments.
- Reset crawler state at the start of each crawl so a reused (cached) instance no
  longer carries pages over from a previous crawl.

### Removed

- **Breaking:** the `disallowedUrls` array is gone from the crawl result. URLs
  skipped by `robots.txt` are reported in `ignored` with reason `"disallowed"`,
  which already carried them, so the separate array was redundant.
