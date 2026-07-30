# sitemap-spider

A ColdBox module that crawls a website and generates an XML sitemap.

It walks a site breadth-first from one or more start URLs, follows links,
honors `robots.txt`, follows redirects, and writes a
[sitemaps.org](https://www.sitemaps.org/protocol.html) `<urlset>` (or a
`<sitemapindex>` for very large sites). By default it fetches static HTML with
[jsoup](https://jsoup.org/). For pages whose links or content are rendered by
JavaScript, an optional [cbPlaywright](https://github.com/coldbox-modules/cbPlaywright)
backend renders the page in a headless browser first.

Source-available under the [PolyForm Perimeter License 1.0.1](LICENSE.md):
free to use in your own sites and client projects, commercial included — just
not to build a competing sitemap product. See [License](#license).

## Requirements

| Requirement | Supported |
| --- | --- |
| ColdBox | 8.x |
| Adobe ColdFusion | 2023+ |
| Lucee | 5, 6 |
| BoxLang | 1 (CFML compatibility mode) |

The only runtime dependency is `cbjavaloader`, which loads the bundled
`lib/jsoup-1.21.2.jar` at module load. jsoup ships inside the package, so no
extra download is needed for the default backend.

> Note: the full test suite (including the Playwright specs) passes on Adobe
> 2023, Lucee 5, Lucee 6, and BoxLang 1.

## Install

```bash
box install sitemap-spider
```

## Quickstart

Get the service and crawl a site. `create()` returns a struct with the crawled
pages, the sitemap XML, and timing.

```cfml
// Crawl one site and get the sitemap XML back
var result = getInstance( "SitemapService@sitemap-spider" )
    .create( "https://example.com/" );

writeOutput( result.sitemap );
```

Start from several URLs, exclude some, and save the XML to disk in one call:

```cfml
var result = getInstance( "SitemapService@sitemap-spider" ).create(
    url         = [ "https://example.com/", "https://example.com/blog/" ],
    excludeUrls = [ "https://example.com/private/" ],
    filePath    = expandPath( "/public/sitemap.xml" )
);

// result.saved is true, result.filePath is where it was written
```

Reach orphan pages that nothing links to by passing them as `seedUrls`. They are
crawled alongside `url`, but the host, `robots.txt` base, and split-file base URL
still come from `url`, so every seed must share its host:

```cfml
var result = getInstance( "SitemapService@sitemap-spider" ).create(
    url      = "https://example.com/",
    seedUrls = [ "https://example.com/orphan-landing.cfm" ]
);
```

## The return struct

`create()` returns a struct with these keys:

| Key | Type | Description |
| --- | --- | --- |
| `pages` | array | Crawled pages, one struct each: `{ url, lastModified, priority, depth, images }`. An array (not a struct keyed by URL) so two URLs that differ only in path case (`/Page` vs `/page`) stay separate. |
| `sitemap` | string | The primary sitemap XML. A `<urlset>` for a normal crawl, or a `<sitemapindex>` when the crawl is split. |
| `type` | string | `"single"` for one file, `"index"` when the output was split into a sitemap index plus child files. |
| `sitemaps` | array | The child sitemap files when `type` is `"index"` (each with `filename`, `xml`, and, if saved, `filePath`). Empty-ish for a single sitemap. |
| `sitemapCount` | number | Number of sitemap files: `1` for a single sitemap, otherwise the child count. |
| `duration` | number | Total crawl + generate time in milliseconds. |
| `processedUrls` | array | Every URL the crawler visited (used to avoid re-visiting). |
| `badUrls` | struct | URLs that failed to fetch or returned a non-HTML / error response, keyed by URL with a `{ message }` value. |
| `ignored` | array | URLs the crawl dropped, each `{ url, reason }`. `reason` is `"nofollow"`, `"excluded"` (matched `excludeUrls` or `excludePattern`), `"disallowed"` (blocked by `robots.txt`), `"noindex"` (the page carries a `noindex` robots directive — see `respectNoIndex`), or `"notAllowed"` (a rejected seed that is off-host, the wrong scheme, or an asset URL). A rejected start/seed URL is reported here too. |
| `redirects` | array | One entry per fetched URL that followed an HTTP redirect: `{ from, to, chain }`. `from` is the requested URL, `to` is the final URL, and `chain` is the hop list, each `{ url, status }`. |
| `filePath` | string | The path passed as `filePath`, or empty when nothing was saved. |
| `saved` | boolean | `true` when the sitemap was written to `filePath`. |

Each entry in `pages` looks like:

```cfml
{
    url          : "https://example.com/about/",
    lastModified : "2026-07-01",  // date-only, or empty when unknown (see lastModFallback)
    priority     : 0.9,           // 1.0 at the start URL, reduced by depth
    depth        : 1,             // link distance from the start URL
    images       : [],            // page image URLs, filled only when includeImages is on
    alternates   : [],            // { hreflang, href } structs, filled only when includeHreflang is on
    videos       : []             // video structs, filled only when includeVideos is on
}
```

Each entry in `videos` looks like:

```cfml
{
    title        : "Product tour",
    description  : "A two minute tour.",
    thumbnailLoc : "https://example.com/thumb.jpg",
    contentLoc   : "https://example.com/tour.mp4",   // the media file, or empty
    playerLoc    : "https://player.example.com/42",  // the player page, or empty
    duration     : 93                                // whole seconds, 0 when unknown
}
```

## Settings

Override any of these in your app's `config/ColdBox.cfc` under
`moduleSettings.sitemap-spider`. Defaults come from `ModuleConfig.cfc`.

| Setting | Default | Effect |
| --- | --- | --- |
| `browserDsl` | `"Jsoup@sitemap-spider"` | Which browser backend fetches each URL. Set to `"Playwright@sitemap-spider"` for JavaScript rendering. |
| `maxDepth` | `10` | Maximum link distance from a start URL to crawl. |
| `maxPages` | `1000` | Maximum number of pages to record in one crawl. |
| `respectRobotsTxt` | `true` | When true, fetches `robots.txt` and honors its `Disallow` / `Allow` rules and `Crawl-delay`. |
| `respectNoIndex` | `true` | When true, a page carrying `<meta name="robots" content="noindex">` (or `none`) or an `X-Robots-Tag: noindex` response header is left out of the sitemap and reported in `ignored` with reason `"noindex"`. Its links are still followed, because `noindex` does not mean `nofollow`. An agent-scoped header directive (`googlebot: noindex`) counts as a global one on purpose. `false` lists such pages anyway. |
| `userAgent` | `"sitemap-spider"` | Sent on every fetch, and matched against `robots.txt` `User-agent` groups. |
| `maxCrawlDelay` | `10` | Upper cap, in seconds, on the `robots.txt` `Crawl-delay` actually applied between fetches. A `Crawl-delay` no longer forces a single-threaded crawl: a parallel crawl still honors it by spacing fetches this far apart across the workers. |
| `notAllowedPattern` | `\.(png\|webp\|svg\|gif\|js\|css\|jpg\|jpeg)$\|javascript:\|mailto:\|tel:` | Links matching this regex are never crawled (asset files and non-HTTP schemes). |
| `excludePattern` | `""` (empty) | Regex matched case-insensitively against the full URL for whole-section excludes (e.g. `/admin/`). A match skips the URL and reports it in `ignored` with reason `"excluded"`. Separate from the per-crawl exact-URL `excludeUrls` argument. Empty means no pattern exclusion. The `create()` `excludePattern` argument overrides this setting for a single crawl. |
| `priority` | `1.0` | `<priority>` assigned to the start URL. |
| `priorityDecrement` | `0.1` | How much `<priority>` drops per level of depth. |
| `maxUrlsPerSitemap` | `50000` | sitemaps.org per-file URL limit. Above this the output splits into a sitemap index. |
| `maxSitemapBytes` | `52428800` | sitemaps.org per-file byte limit (50 MiB, uncompressed). Above this the output splits. |
| `gzipOutput` | `false` | When true and a `filePath` is given, the sitemap files are written gzip-compressed with a `.gz` suffix (e.g. `sitemap.xml.gz`). Child files and the `<sitemapindex>` `<loc>` entries carry `.gz` too. See the note below on serving `.gz`. |
| `lastModFormat` | `"date"` | Format of `<lastmod>`: `"date"` writes the date-only form (`YYYY-MM-DD`); `"datetime"` writes the full W3C timestamp (`YYYY-MM-DDThh:mm:ss+HH:MM`) in the server's local timezone. |
| `includeImages` | `false` | When true, each page's `<img src>` images are emitted as `<image:image>` entries and the `<urlset>` gains the image namespace. Images are not host-filtered (CDN images are kept), capped at 1000 per page. The `create()` `includeImages` argument overrides this setting for a single crawl. |
| `includeHreflang` | `false` | When true, each page's `<link rel="alternate" hreflang="...">` tags are emitted as `<xhtml:link>` entries and the `<urlset>` gains the xhtml namespace. Alternates are emitted exactly as declared — off-host targets are kept (hreflang usually points at other domains) and `x-default` is allowed. Capped at 1000 per page. The `create()` `includeHreflang` argument overrides this setting for a single crawl. |
| `includeVideos` | `false` | When true, each page's videos are emitted as `<video:video>` blocks and the `<urlset>` gains the video namespace. Videos are read from three sources: JSON-LD `VideoObject` blocks, Open Graph tags (`og:video` becomes `<video:player_loc>`) and `<video>` elements (`src` or a `<source src>` child becomes `<video:content_loc>`, `poster` the thumbnail). The title and description fall back to `og:title`/`<title>` and `og:description`/meta description; the thumbnail falls back to `og:image`. A video still missing a required field (thumbnail, title, description, or a URL) is dropped. Capped at 100 per page. The `create()` `includeVideos` argument overrides this setting for a single crawl. |
| `lastModFallback` | `"omit"` | What `<lastmod>` does when a page has no parseable Last-Modified: `"omit"` leaves it out; `"crawlTime"` records the crawl timestamp. |
| `requestTimeout` | `10000` | Per-request timeout in milliseconds. |
| `maxBodySize` | `5242880` | Cap (bytes) on the response body a fetch downloads (5 MB). |
| `maxRedirects` | `20` | Most HTTP redirect hops the Jsoup backend follows for one URL before recording it as bad. It follows redirects itself so it can enforce this and report the hop `chain` (see `redirects` above). The Playwright backend uses the browser's own limit. |
| `waitStrategy` | `"networkidle"` | Playwright backend only. Page load state to wait for after navigation (`"load"` or `"networkidle"`). |
| `waitMs` | `0` | Playwright backend only. Extra fixed wait (ms) after navigation, for content injected by a `setTimeout` with no network activity. Applies to every fetch, so prefer `waitForSelector` when you can name the element. |
| `waitForSelector` | `""` (empty) | Playwright backend only. CSS selector to wait for after navigation, before reading the page. Returns as soon as the element appears (bounded by `requestTimeout`), so it is faster than a large blanket `waitMs`. A selector that never appears logs a warning and the fetch continues. Empty disables it; combines with `waitMs`. |
| `libPath` | `<modulePath>/lib` | Directory cbjavaloader loads the jsoup jar from. |
| `htmlContentTypePattern` | `^(text/html\|application/xhtml\+xml)(;.*)?$` | Only responses whose content type matches are parsed for links and canonical URLs. |

These apply only to background jobs (see [Background jobs](#background-jobs)):

| Setting | Default | Effect |
| --- | --- | --- |
| `maxConcurrentJobs` | `3` | How many queued crawls run at once. The rest wait as `queued` and start as slots free up. Each job crawls single-threaded, so this is roughly the live thread count — and, when jobs use the Playwright backend, the number of browser processes. |
| `maxRetainedJobs` | `100` | How many finished job records to keep. The oldest are dropped past this. `0` or less keeps everything. |
| `jobStoreDsl` | `"InMemoryJobStore@sitemap-spider"` | Where job records are kept. The default keeps them in memory, so they are lost on a restart. Point it at your own `IJobStore` to keep them. |
| `jobNodeId` | `""` (empty) | Names this app server in job records. Empty uses the machine's host name. Only matters when several servers share one job store. |
| `jobHeartbeatSeconds` | `15` | How often a running job writes its counters and a "still alive" timestamp to the store. |
| `jobStaleSeconds` | `90` | How long a job can go without reporting progress before it is treated as dead and marked `interrupted`. Keep it several times `jobHeartbeatSeconds` so a slow garbage-collection pause never kills a healthy job. |
| `jobReaperEnabled` | `true` | Whether the background task that marks dead jobs `interrupted` runs. |
| `jobReaperIntervalSeconds` | `60` | How often that task runs. |

## Browser backends

The `browserDsl` setting selects how each URL is fetched. Both backends share
the `IBrowser` interface in `models/browsers/`.

| Backend | `browserDsl` | Use it for |
| --- | --- | --- |
| jsoup (default) | `Jsoup@sitemap-spider` | Static HTML. Fast, no extra dependency. Links and content already present in the server-rendered HTML. |
| Playwright | `Playwright@sitemap-spider` | Pages whose links or content are added by JavaScript in the browser. Requires the optional `cbPlaywright` module. |

`browserDsl` is a global setting, but the `create()` and
`SitemapJobRegistry.queue()` `browserDsl` argument overrides it for a single
crawl. Use that when you crawl several sites and only some of them need
JavaScript rendering — each Playwright crawl runs its own browser process, so it
is worth pointing only the sites that need it at that backend.

## cbPlaywright setup (optional)

The Playwright backend renders each page in a headless Chromium browser, so it
sees links and content that JavaScript adds after load. It needs some setup:

1. **Install the module:**

   ```bash
   box install cbPlaywright
   ```

2. **Install a matching browser.** The cbPlaywright driver pins an exact
   Chromium revision. A browser from a different Playwright version does not
   satisfy it, and launch fails with `Executable doesn't exist at ...`. Install
   the matching build through the driver's own Node CLI, for example:

   ```bash
   <driver>/node.exe cli.js install chromium-headless-shell
   ```

3. **Put the cbPlaywright jars on the CF class path** with `this.javaSettings`
   in your `Application.cfc`. If you also run the module's specs, do the same in
   `tests/Application.cfc` — the TestBox runner uses a separate Application, and
   missing jars there cause a `Class not found: PlaywrightImpl` error that only
   appears under the runner.

   ```cfml
   this.cbPlaywrightLib = expandPath( "/modules/cbPlaywright/lib" );
   if ( directoryExists( this.cbPlaywrightLib ) ) {
       this.javaSettings = {
           loadPaths               : directoryList( this.cbPlaywrightLib, true, "array", "*.jar" ),
           loadColdFusionClassPath : true,
           reloadOnChange          : false
       };
       // Lets the backend include cbPlaywright's helper mixin and version file
       this.mappings[ "/cbPlaywright" ] = expandPath( "/modules/cbPlaywright" );
   }
   ```

4. **Tune the wait** with `waitStrategy`, `waitForSelector`, and `waitMs`.
   `waitStrategy` is the page load state to wait for (`"networkidle"` by
   default). `waitForSelector` waits for a specific element to appear and returns
   as soon as it does, so it is the fast way to wait for a known JS-injected
   element. `waitMs` is an extra fixed wait applied after navigation — needed
   when content is injected by a `setTimeout` with no network activity and you
   cannot name a selector. Note that `waitMs` applies to every page fetch, so a
   large crawl with a high `waitMs` is slow; prefer `waitForSelector` where you
   can.

> **Single-threaded, and clean shutdown matters.** The Playwright backend always
> runs on one thread. A `runAsync = true` crawl with this backend downgrades to
> single-threaded (and logs it), because Playwright pins each browser to the one
> thread that created it, so parallel fetching is not possible on a shared
> instance. Also stop the server cleanly (`box server stop`, or let a crawl
> finish normally) — the backend closes the browser and its driver when a crawl
> ends, but a hard kill of the JVM can leave orphaned Chromium `headless_shell`
> processes behind. Running in a container is the reliable fix for that, since
> the browser processes go away with it. A ColdBox reinit is safe: the crawl
> closes its own browser as it stops.
>
> Each crawl using this backend runs its own browser, so several at once is
> expensive. When queueing background jobs, keep `maxConcurrentJobs` low or point
> only the sites that need JavaScript at this backend with the per-crawl
> `browserDsl` argument.

## Output and splitting

- **`<lastmod>`** is written date-only (`YYYY-MM-DD`), which is valid per
  sitemaps.org. When a page has no parseable Last-Modified, `lastModFallback`
  decides whether the element is omitted or filled with the crawl time.
- **Splitting** into a `<sitemapindex>` plus numbered child sitemaps happens
  only when a crawl exceeds `maxUrlsPerSitemap` (50000) or `maxSitemapBytes`
  (50 MiB). Because the default `maxPages` is 1000, a default crawl never
  splits — raise `maxPages` well past 50000 to reach the limit.
- **`filePath`** saves the primary sitemap there (creating the directory if
  needed). When the output splits, that path receives the `<sitemapindex>` and
  each child sitemap is written beside it. A write failure throws
  `sitemap-spider.SaveFailed`.
- **`publicBaseUrl`** is the absolute URL prefix the child sitemaps are served
  from, used for the `<sitemapindex>` `<loc>` entries. When omitted, it is
  derived from the first start URL's directory.
- **Gzip** (`gzipOutput = true`) writes each file compressed with a `.gz` name.
  Your web server must serve these `.gz` files with the `Content-Encoding: gzip`
  header (or as an already-gzipped body a crawler will decompress) — otherwise a
  search engine fetching the URL sees raw binary. The module writes the files; it
  does not configure your server.
- **Full timestamps** (`lastModFormat = "datetime"`) write
  `YYYY-MM-DDThh:mm:ss+HH:MM` in the server's local timezone. A page whose date is
  known only to the day (no time) renders at midnight local (`T00:00:00`).
- **Image sitemaps** (`includeImages = true`) add `<image:image>` entries per
  page from its `<img src>` tags, plus the
  `xmlns:image="http://www.google.com/schemas/sitemap-image/1.1"` namespace on
  the `<urlset>`.
- **hreflang alternates** (`includeHreflang = true`) add an `<xhtml:link
  rel="alternate" hreflang="..." href="..."/>` per declared alternate on each
  `<url>`, plus the `xmlns:xhtml="http://www.w3.org/1999/xhtml"` namespace on
  the `<urlset>`.
- **Video sitemaps** (`includeVideos = true`) add `<video:video>` blocks per
  page (thumbnail, title, description, then a content and/or player URL, then
  duration in seconds when known), plus the
  `xmlns:video="http://www.google.com/schemas/sitemap-video/1.1"` namespace on
  the `<urlset>`. Videos come from three sources, read in this order:

  | Source | Media URL | Player URL | Title and description |
  | --- | --- | --- | --- |
  | JSON-LD `VideoObject` | `contentUrl` | `embedUrl` | its own `name` and `description` |
  | Open Graph | — | `og:video` | the page's |
  | `<video>` element | `src` or `<source src>` | — | the page's |

  JSON-LD is read first on purpose. A `VideoObject` describes one specific
  video, so its own title, description and `thumbnailUrl` beat the page-level
  text the other two sources fall back to, and it is the only source that can
  give both a media URL and a player URL. When two sources name the same URL,
  the earlier one wins and the later one is dropped. `VideoObject` entries are
  found wherever they sit in the block: at the top level, in an array, under
  `@graph`, or nested inside another type. A block that is not valid JSON is
  skipped and the crawl carries on.

  `<video:duration>` comes from the JSON-LD `duration` field, converted from
  ISO 8601 (`PT1M33S`) to the whole seconds the sitemap protocol wants. A value
  that cannot be read, or that falls outside Google's 1–28800 second range, is
  left out. The other two sources carry no duration.

- **Per-crawl extension flags.** All three settings above are global, but
  `create()` and `SitemapJobRegistry.queue()` take `includeImages`,
  `includeHreflang` and `includeVideos` as arguments that override the setting
  for one crawl, in either direction. Omit the argument to use the setting.
  A host generating sitemaps for many sites needs this, because the right
  extensions differ per site:

  ```cfml
  sitemapService.create( url = "https://example.com/", includeVideos = true );
  ```

## Background jobs

`SitemapService.create()` blocks until the crawl finishes, which is fine for one
site. To crawl several sites at once, watch their progress, and let a user cancel
one, use `SitemapJobRegistry` instead. It hands the crawl to a background thread
pool and gives you back a job id right away.

```cfml
property name="jobs" inject="SitemapJobRegistry@sitemap-spider";

// Returns immediately. filePath is required: a background job has no response to
// write to, so it saves the file for you to serve or upload later.
var jobId = jobs.queue(
    url      = "https://example.com/",
    filePath = expandPath( "/sitemaps/example.xml" )
);

var job = jobs.getJob( jobId );
// job.status   -> queued | running | completed | failed | canceled | interrupted
// job.progress -> { pagesFound, urlsProcessed, badUrls, remaining, elapsedMs, ... }
// job.result   -> { saved, filePath, type, sitemapCount } once it completes

jobs.listJobs();            // every job, newest first
jobs.cancel( jobId );       // stops after the page it is on
jobs.remove( jobId );       // drops the record
```

`maxConcurrentJobs` (default 3) sets how many run at once; the rest wait as
`queued` and start as slots free up. Each job crawls single-threaded, so the live
thread count stays near that number. Passing `runAsync = true` to a job makes that
one crawl use several threads too, which multiplies threads
(`maxConcurrentJobs` × `asyncMaxThreads` at worst) — keep that within your
engine's thread pool.

### Per-site options

`queue()` takes the same crawl arguments as `create()`, plus:

- **`browserDsl`** picks the backend for that job, e.g.
  `"Playwright@sitemap-spider"` for a site whose links need JavaScript. Empty uses
  the `browserDsl` setting. Each Playwright job runs its own browser process, so
  keep `maxConcurrentJobs` low if several sites use it. `create()` accepts this
  argument too.
- **`includeImages`, `includeHreflang`, `includeVideos`** turn each sitemap
  extension on or off for that job, overriding the module setting. Omit one to
  use the setting. The values are resolved when the job is queued and stored on
  its record, so a job runs with the settings it was queued under even if a
  setting changes before its turn comes up.
- **`meta`** is a struct of your own values (site id, customer id, anything). It
  is stored as-is, returned with every read, and can be filtered on:
  `jobs.listJobs( { customerId : "acme" } )`. This module never looks inside it.
  You can also filter by status: `jobs.listJobs( { status : "running" } )`.

### Reacting to jobs

The module announces these ColdBox interception points, each with
`{ jobId, record }`. Listen to them to upload the finished file, email someone, or
decide whether to retry — no need for this module to know about any of that.
Announcing an event nobody listens for does nothing.

| Point | When |
| --- | --- |
| `onSitemapJobQueued` | A job was accepted |
| `onSitemapJobStarted` | A worker picked it up |
| `onSitemapJobCompleted` | The crawl finished and the file was written |
| `onSitemapJobFailed` | The crawl threw |
| `onSitemapJobInterrupted` | It was canceled, or its process died |

### What happens when the app restarts or crashes

A crawl runs in memory, so it cannot survive the JVM going away, and a
breadth-first crawl cannot cheaply resume part way through. Instead, jobs that
stop unexpectedly are marked `interrupted` so nothing is left looking active and
you can decide whether to run it again.

| What happened | How it is handled |
| --- | --- |
| ColdBox reinit (`?fwreinit=1`) | The module cancels its running crawls and records them as `interrupted` before the framework rebuilds |
| Server stopped or killed, out of memory | No code runs, so nothing is recorded at the time. A background task notices the job stopped reporting progress (`jobStaleSeconds`) and marks it `interrupted` |
| App restarted, durable store in use | At startup, jobs left `running` by the previous start are recognised by their boot id and marked `interrupted` immediately |

That upkeep runs automatically — `config/Scheduler.cfc` ships with the module and
needs no wiring. It writes each running job's counters to the store every
`jobHeartbeatSeconds`, which is also what makes progress visible for a job running
on another server. Set `jobReaperEnabled = false` to turn the cleanup off.

### Keeping job records

By default records live in memory (`InMemoryJobStore`) and are lost on a restart.
The saved sitemap files are not affected. To keep records, write a component
implementing `IJobStore` (see
[models/jobs/IJobStore.cfc](models/jobs/IJobStore.cfc)) and point the module at
it:

```cfml
moduleSettings = {
    "sitemap-spider" : { jobStoreDsl : "MyDbJobStore@myapp" }
};
```

The interface is small, and the counters that change constantly during a crawl
never reach it — a store only sees status changes and a heartbeat, so a few writes
per job. Two methods carry the important rules:

- **`claim()`** must move a job from `queued` to `running` for exactly one caller.
  With a database that is a conditional update
  (`... set status = 'running' where id = ? and status = 'queued'`) checking that
  one row changed. This is what lets more than one app server share a job store
  without running the same job twice.
- **`save()`** with an `expectedOwnerId` must only write if the job still belongs
  to that owner. This drops a late write from a crawl thread that outlived a
  reinit, after its job was already marked interrupted and re-claimed.

Two things stay your responsibility with a durable store: jobs still sitting in
`queued` when the app stops are not picked back up automatically (the in-process
pool queue went away with it, so re-queue them at startup), and deciding whether
to retry an `interrupted` job — the record's `attempts` count is there to cap it.

## Releasing (maintainers)

Releases are manual (there is no CI). To cut and publish a new version:

1. Bump `version` in `box.json` (semver: patch for fixes, minor for additive
   features, major for breaking changes).
2. Roll the changelog: rename the `[Unreleased]` section in `changelog.md` to the
   new version with today's date, and start a fresh empty `[Unreleased]` above it.
3. Run `box run-script release`. This builds the module (stamping the box.json
   version into `ModuleConfig.cfc`'s `this.version`) and publishes the stamped
   package to ForgeBox. It runs `release.boxr` under the hood.
4. Commit the version and changelog bumps, then tag: `git tag v<version>`.

`box run-script build:module` on its own produces the release artifact under
`.artifacts/sitemap-spider/<version>/` (a version-stamped zip plus `.sha512` and
`.md5` checksums) without publishing — handy for inspecting a build first.

## Third-party software

This package bundles [jsoup](https://jsoup.org/) (`lib/jsoup-1.21.2.jar`),
copyright Jonathan Hedley, used under the MIT License. jsoup's own terms apply
to it, not the terms below.

## License

The complete source code is publicly available under the
[PolyForm Perimeter License 1.0.1](LICENSE.md).

In plain terms:

- **You may** use this module in personal and commercial website projects,
  including client work. You may modify it and redistribute it.
- **You may not** use it to provide a competing sitemap generation product or
  hosted sitemap generation service.

That summary is here to save you a read. The text in
[LICENSE.md](LICENSE.md) is what actually governs your use.

sitemap-spider is not open source, and we don't describe it that way. The Open
Source Definition doesn't allow a license to restrict a field of use, and
PolyForm Perimeter restricts exactly one: competing with this module.
Everything else is allowed.

Copyright Angry Sam Productions, Inc.
