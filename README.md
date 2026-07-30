# sitemap-spider

![Sitemap Spider Logo](https://github.com/homestar9/sitemap-spider/blob/master/sitemap-spider-logo.avif?raw=true)

A ColdBox module that crawls a website and generates an XML sitemap.

It starts from one or more URLs and follows links breadth-first. It honors
`robots.txt`, follows redirects, and writes a
[sitemaps.org](https://www.sitemaps.org/protocol.html) `<urlset>` (or a
`<sitemapindex>` for very large sites). By default it fetches static HTML with
[jsoup](https://jsoup.org/). For pages whose links or content are rendered by
JavaScript, the optional
[cbPlaywright](https://github.com/coldbox-modules/cbPlaywright) backend uses a
headless browser.

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

The full test suite, including Playwright specs, passes on every supported
engine.

## Install

```bash
box install sitemap-spider
```

## Quickstart

Call `create()` to crawl a site. It returns the pages, sitemap XML, and timing.

```cfml
// Crawl one site.
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

// result.saved is true and result.filePath contains the saved path.
```

Use `seedUrls` for pages that other pages do not link to. The `url` argument
still sets the host, `robots.txt` base, and split-file base URL. Every seed must
use that host.

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
| `pages` | array | Crawled page structs. The array keeps case-sensitive paths such as `/Page` and `/page` separate. |
| `sitemap` | string | The primary sitemap XML. A `<urlset>` for a normal crawl, or a `<sitemapindex>` when the crawl is split. |
| `type` | string | `"single"` for one file, `"index"` when the output was split into a sitemap index plus child files. |
| `sitemaps` | array | Child sitemaps when `type` is `"index"`. Each contains `filename`, `xml`, and an optional `filePath`. Empty for one sitemap. |
| `sitemapCount` | number | Number of sitemap files: `1` for a single sitemap, otherwise the child count. |
| `duration` | number | Total crawl + generate time in milliseconds. |
| `stats` | struct | Counts for dashboards and job records: `{ generatedAt, durationMs, urlCount, sitemapCount, type, badUrlCount, ignoredCount, redirectCount }`. `generatedAt` is an ISO-8601 timestamp with the server's UTC offset. `durationMs` equals `duration`. |
| `processedUrls` | array | Every URL the crawler visited. |
| `badUrls` | struct | URLs that failed to fetch or returned a non-HTML / error response, keyed by URL with a `{ message }` value. |
| `ignored` | array | Skipped URLs as `{ url, reason }`. Reasons are `"nofollow"`, `"excluded"`, `"disallowed"`, `"noindex"`, and `"notAllowed"`. Rejected start and seed URLs also appear here. |
| `redirects` | array | One entry per fetched URL that followed an HTTP redirect: `{ from, to, chain }`. `from` is the requested URL, `to` is the final URL, and `chain` is the hop list, each `{ url, status }`. |
| `filePath` | string | The path passed as `filePath`, or empty when nothing was saved. |
| `saved` | boolean | `true` when the sitemap was written to `filePath`. |
| `metadataPath` | string | Where the metadata sidecar was written, or empty when none was. See `writeMetadata`. |
| `metadataSaved` | boolean | `true` when the metadata sidecar was written. |

Each entry in `pages` looks like:

```cfml
{
    url          : "https://example.com/about/",
    lastModified : "2026-07-01",  // Empty when unknown. See lastModFallback.
    priority     : 0.9,           // Starts at 1.0 and decreases with depth.
    depth        : 1,             // Link distance from the start URL.
    images       : [],            // Filled when includeImages is true.
    alternates   : [],            // Filled when includeHreflang is true.
    videos       : []             // Filled when includeVideos is true.
}
```

Each entry in `videos` looks like:

```cfml
{
    title        : "Product tour",
    description  : "A two minute tour.",
    thumbnailLoc : "https://example.com/thumb.jpg",
    contentLoc   : "https://example.com/tour.mp4",   // Media file, or empty.
    playerLoc    : "https://player.example.com/42",  // Player page, or empty.
    duration     : 93                                // Seconds, or 0 when unknown.
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
| `runAsync` | `false` | Uses `asyncMaxThreads` workers when the backend supports parallel fetches. Workers share the `robots.txt` crawl delay. The `create()` argument overrides this setting for one crawl. |
| `asyncMaxThreads` | `10` | Worker thread count for a parallel crawl. Only used when `runAsync` is on. |
| `respectRobotsTxt` | `true` | Honors `robots.txt` `Disallow`, `Allow`, and `Crawl-delay`. Rules use prefix matching, so `/admin/` does not match `/admin`. |
| `respectNoIndex` | `true` | Omits pages marked `noindex` by a robots meta tag or `X-Robots-Tag` header. Their links are still followed. An agent-scoped header such as `googlebot: noindex` also counts. |
| `userAgent` | `"sitemap-spider"` | Sent on every fetch, and matched against `robots.txt` `User-agent` groups. |
| `maxCrawlDelay` | `10` | Maximum `robots.txt` crawl delay in seconds. Parallel workers share this delay between fetches. |
| `notAllowedPattern` | `\.(png\|webp\|svg\|gif\|js\|css\|jpg\|jpeg)$\|javascript:\|mailto:\|tel:` | Links matching this regex are never crawled (asset files and non-HTTP schemes). |
| `excludePattern` | `""` (empty) | Case-insensitive regex matched against the full URL. A match adds reason `"excluded"` to `ignored`. `excludeUrls` handles exact URLs. The `create()` argument overrides this setting for one crawl. |
| `sessionParams` | `cfid,cftoken,jsessionid,utm_source,...` | Query-param and `;jsessionid` path-param names stripped during URL normalization, so session tokens and tracking params never reach dedup keys or the sitemap. Matched case-insensitively. The full default list also covers `utm_medium`, `utm_campaign`, `utm_term`, `utm_content`, `fbclid`, and `gclid`. |
| `priority` | `1.0` | `<priority>` assigned to the start URL. |
| `priorityDecrement` | `0.1` | How much `<priority>` drops per level of depth. |
| `maxUrlsPerSitemap` | `50000` | sitemaps.org per-file URL limit. Above this the output splits into a sitemap index. |
| `maxSitemapBytes` | `52428800` | sitemaps.org per-file byte limit (50 MiB, uncompressed). Above this the output splits. |
| `gzipOutput` | `false` | Saves compressed files with a `.gz` suffix. Child filenames and index locations also include `.gz`. See [Output and splitting](#output-and-splitting). |
| `writeMetadata` | `false` | When true, writes a JSON sidecar holding the `stats` struct, crawl options, and module version. It uses `metadataPath` when configured, otherwise it is written next to `filePath` (`sitemap.xml` → `sitemap.xml.meta.json`). Read it later with `readMetadata()` — see [Host app integration](#host-app-integration). |
| `metadataPath` | `""` (empty) | Default metadata filename. Set it outside the webroot to keep it private. An omitted method argument uses this setting. A non-empty argument replaces it. An explicit empty argument saves beside the sitemap. Use a distinct path for each crawl or job. |
| `metadataIncludeUrls` | `false` | Adds full `badUrls` and `ignored` lists to metadata. Store this file outside the webroot or block `*.meta.json` at the web server. |
| `lastModFormat` | `"date"` | Format of `<lastmod>`: `"date"` writes the date-only form (`YYYY-MM-DD`); `"datetime"` writes the full W3C timestamp (`YYYY-MM-DDThh:mm:ss+HH:MM`) in the server's local timezone. |
| `includeImages` | `false` | Adds `<img src>` URLs as `<image:image>`. Keeps off-host CDN images and limits each page to 1000 images. The `create()` argument overrides this setting for one crawl. |
| `includeHreflang` | `false` | Adds alternate links as `<xhtml:link>`. Keeps off-host targets and `x-default`, with a limit of 1000 per page. The `create()` argument overrides this setting for one crawl. |
| `includeVideos` | `false` | Adds `<video:video>` from JSON-LD, Open Graph, and `<video>` elements. Omits videos missing a thumbnail, title, description, or media/player URL. Limits each page to 100 videos. The `create()` argument overrides this setting for one crawl. |
| `lastModFallback` | `"omit"` | What `<lastmod>` does when a page has no parseable Last-Modified: `"omit"` leaves it out; `"crawlTime"` records the crawl timestamp. |
| `requestTimeout` | `10000` | Per-request timeout in milliseconds. |
| `maxBodySize` | `5242880` | Cap (bytes) on the response body a fetch downloads (5 MB). |
| `maxRedirects` | `20` | Maximum redirect hops for Jsoup. Exceeding it records a bad URL. Playwright uses its browser limit. |
| `waitStrategy` | `"networkidle"` | Playwright backend only. Page load state to wait for after navigation (`"load"` or `"networkidle"`). |
| `waitMs` | `0` | Playwright only. Fixed wait after every navigation. Prefer `waitForSelector` for a known element. |
| `waitForSelector` | `""` (empty) | Playwright only. Waits up to `requestTimeout` for a CSS selector. A timeout logs a warning and continues. |
| `libPath` | `<modulePath>/lib` | Directory cbjavaloader loads the jsoup jar from. |
| `htmlContentTypePattern` | `^(text/html\|application/xhtml\+xml)(;.*)?$` | Only responses whose content type matches are parsed for links and canonical URLs. |

These apply only to background jobs (see [Background jobs](#background-jobs)):

| Setting | Default | Effect |
| --- | --- | --- |
| `maxConcurrentJobs` | `3` | Jobs that can run at once. Other jobs remain `queued`. Each Playwright job starts a browser process. |
| `maxRetainedJobs` | `100` | How many finished job records to keep. The oldest are dropped past this. `0` or less keeps everything. |
| `jobStoreDsl` | `"InMemoryJobStore@sitemap-spider"` | Where job records are kept. The default keeps them in memory, so they are lost on a restart. Point it at your own `IJobStore` to keep them. |
| `jobNodeId` | `""` (empty) | Names this app server in job records. Empty uses the machine's host name. Only matters when several servers share one job store. |

The next four settings apply only when `IJobStore.isShared()` returns `true`.
The default in-memory store does not schedule these tasks. See
[Background upkeep](#what-happens-when-the-app-restarts-or-crashes).

| Setting | Default | Effect |
| --- | --- | --- |
| `jobHeartbeatSeconds` | `30` | How often a running job writes its counters and a "still alive" timestamp to the store. |
| `jobStaleSeconds` | `180` | How long a job can go without reporting progress before it is treated as dead and marked `interrupted`. Keep it several times `jobHeartbeatSeconds` so a slow garbage-collection pause never kills a healthy job. |
| `jobReaperEnabled` | `true` | Enables stale-job recovery for a shared store. |
| `jobReaperIntervalSeconds` | `120` | How often that task runs. Worst case time to notice a dead job is this plus `jobStaleSeconds`. |

## Browser backends

The `browserDsl` setting selects how each URL is fetched. Both backends share
the `IBrowser` interface in `models/browsers/`.

| Backend | `browserDsl` | Use it for |
| --- | --- | --- |
| jsoup (default) | `Jsoup@sitemap-spider` | Static HTML. Fast, no extra dependency. Links and content already present in the server-rendered HTML. |
| Playwright | `Playwright@sitemap-spider` | Pages whose links or content are added by JavaScript in the browser. Requires the optional `cbPlaywright` module. |

The `browserDsl` argument to `create()` or `SitemapJobRegistry.queue()` overrides
the setting for one crawl. Each Playwright crawl starts a browser process, so
use it only for sites that need JavaScript.

## cbPlaywright setup (optional)

Playwright renders JavaScript in headless Chromium. Set it up as follows:

1. **Install the module:**

   ```bash
   box install cbPlaywright
   ```

2. **Install the matching browser.** cbPlaywright requires its exact Chromium
   revision. A different revision causes `Executable doesn't exist at ...`.
   Use the driver's Node CLI:

   ```bash
   <driver>/node.exe cli.js install chromium-headless-shell
   ```

3. **Add the cbPlaywright jars to the CF classpath** in `Application.cfc`. Also
   add them to `tests/Application.cfc` when running specs because TestBox uses a
   separate application. Missing test jars cause `Class not found:
   PlaywrightImpl`.

   ```cfml
   this.cbPlaywrightLib = expandPath( "/modules/cbPlaywright/lib" );
   if ( directoryExists( this.cbPlaywrightLib ) ) {
       this.javaSettings = {
           loadPaths               : directoryList( this.cbPlaywrightLib, true, "array", "*.jar" ),
           loadColdFusionClassPath : true,
           reloadOnChange          : false
       };
       // Let Playwright.cfc include cbPlaywright helpers.
       this.mappings[ "/cbPlaywright" ] = expandPath( "/modules/cbPlaywright" );
   }
   ```

4. **Choose a wait.** `waitStrategy` selects `"load"` or `"networkidle"`.
   `waitForSelector` returns when a known element appears. Use `waitMs` only
   when code adds content later and no selector can identify it. `waitMs`
   slows every page.

> Playwright must use the thread that created its browser. The backend therefore
> changes `runAsync = true` to a single-threaded crawl and logs the change.
> Stop the server cleanly so the crawl can close Chromium. A hard JVM kill can
> leave `headless_shell` processes behind. Containers remove these processes
> when the container stops. ColdBox reinit cancels the crawl and closes its
> browser.
>
> Each Playwright crawl starts a browser. Keep `maxConcurrentJobs` low when
> several jobs use this backend.

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

  JSON-LD is read first. Its title, description, and `thumbnailUrl` replace
  page-level fallbacks. It can also provide both media and player URLs. When
  sources contain the same URL, the first source wins. `VideoObject` can appear
  at the top level, in an array, under `@graph`, or inside another type. Invalid
  JSON is skipped.

  `<video:duration>` comes from the JSON-LD `duration` field, converted from
  ISO 8601 (`PT1M33S`) to the whole seconds the sitemap protocol wants. A value
  that cannot be read, or that falls outside Google's 1–28800 second range, is
  left out. The other two sources carry no duration.

- **Per-crawl extension flags.** `create()` and `SitemapJobRegistry.queue()`
  accept `includeImages`, `includeHreflang`, and `includeVideos`. Each argument
  overrides its setting for one crawl. Omit it to use the setting.

  ```cfml
  sitemapService.create( url = "https://example.com/", includeVideos = true );
  ```

## Host app integration

Host applications usually save the sitemap in the webroot, list it in
`robots.txt`, and save generation statistics.

**Keep crawl scope deliberate.** robots.txt paths are prefix matches, and a
trailing slash is significant. `Disallow: /admin/` blocks descendants such as
`/admin/users`, but it does not block a link to `/admin`. A slashless
`Disallow: /admin` blocks both, but also blocks `/administrator`. To target only
the exact route and its descendants, use:

```text
User-agent: *
Disallow: /admin$
Disallow: /admin/
```

For a sitemap-specific safety net independent of robots.txt, configure
`excludePattern = "/admin(?:/|\?|$)"`.

URL paths also remain distinct after normalization: repeated slashes such as
`//about/` collapse to `/about/`, but `/about` and `/about/` are not merged.
Sites that serve the same page at both URLs should emit one consistent link
form and redirect the other, or declare a common `rel="canonical"`.

**Write into the webroot.** Search engines expect `/sitemap.xml` at the site
root, so pass that as `filePath`:

```cfml
property name="sitemapService" inject="SitemapService@sitemap-spider";

var result = sitemapService.create(
    url           = "https://example.com/",
    filePath      = expandPath( "/sitemap.xml" ),
    writeMetadata = true
);
```

Most web servers serve this physical file without a ColdBox route. Add generated
files to `.gitignore`.

**Point robots.txt at it.** Add one line so crawlers find the sitemap without
being told:

```
Sitemap: https://example.com/sitemap.xml
```

**Save stats without job records.** Use a private path so URL details cannot
become public:

```cfml
moduleSettings = {
    "sitemap-spider" : {
        metadataPath : expandPath( "/../private/sitemap.xml.meta.json" )
    }
};
```

With `writeMetadata` enabled, generation writes the sidecar to `metadataPath`.
An empty path writes `sitemap.xml.meta.json` beside the sitemap. The file
remains available after in-memory job records disappear.

```cfml
var metadata = sitemapService.readMetadata( expandPath( "/sitemap.xml" ) );
if ( metadata.exists ) {
    // Read metadata.stats, metadata.options, and metadata.moduleVersion.
}
```

`readMetadata()` accepts a sitemap or sidecar path. It returns
`{ exists : false }` for a missing or invalid file. A sitemap path uses the
configured `metadataPath`; a `.meta.json` path is read directly. When one crawl
overrides the setting, read its returned `result.metadataPath`. Keep
`metadataIncludeUrls` disabled unless the file is private.

**Add a non-blocking generate button.** `create()` waits for the crawl. For an
admin action, queue a job and poll it or listen for its completion event.

```cfml
property name="jobs" inject="SitemapJobRegistry@sitemap-spider";

// Returns a job id immediately; the crawl runs on a pool thread.
var jobId = jobs.queue(
    url           = "https://example.com/",
    filePath      = expandPath( "/sitemap.xml" ),
    writeMetadata = true
);

// Poll jobs.getJob( jobId ).progress or listen for completion events.
```

See [Background jobs](#background-jobs) for the full job API, and
[Keeping job records](#keeping-job-records) if you want job history to survive
restarts too.

## Background jobs

`SitemapService.create()` waits for the crawl to finish.
`SitemapJobRegistry.queue()` returns a job ID and runs the crawl on a background
thread pool. Use it for concurrent crawls, progress, or cancellation.

```cfml
property name="jobs" inject="SitemapJobRegistry@sitemap-spider";

// filePath is required because the background job must save its output.
var jobId = jobs.queue(
    url      = "https://example.com/",
    filePath = expandPath( "/sitemaps/example.xml" )
);

var job = jobs.getJob( jobId );
// job.status   -> queued | running | completed | failed | canceled | interrupted
// job.progress -> { pagesFound, urlsProcessed, badUrls, remaining, elapsedMs, ... }
// job.result   -> { saved, filePath, type, sitemapCount, stats,
//                   metadataPath, metadataSaved } once it completes

jobs.listJobs();            // every job, newest first
jobs.cancel( jobId );       // stops after the page it is on
jobs.remove( jobId );       // drops the record
```

`maxConcurrentJobs` sets the running-job limit. Other jobs remain `queued`.
Each job is single-threaded unless it receives `runAsync = true`. The maximum
crawl worker count is then `maxConcurrentJobs × asyncMaxThreads`; keep it within
the engine's thread limit.

### Per-site options

`queue()` takes the same crawl arguments as `create()`, plus:

- **`browserDsl`** selects the backend. Empty uses the module setting.
  `create()` also accepts this argument. Each Playwright job starts a browser.
- **`includeImages`, `includeHreflang`, `includeVideos`** override module
  settings for that job. Values are saved when the job is queued, so later
  setting changes do not affect it.
- **`writeMetadata`, `metadataPath`, `metadataIncludeUrls`** control the job's
  JSON sidecar. These values are also saved at queue time. An explicit empty
  path saves beside the sitemap. The result includes `stats`, `metadataPath`,
  and `metadataSaved`.
- **`meta`** stores your own values without interpreting them. Filter these
  values with `jobs.listJobs( { customerId : "acme" } )`. You can also filter
  status with `jobs.listJobs( { status : "running" } )`.

### Reacting to jobs

The module announces these ColdBox interception points with `{ jobId, record }`.
Listeners can upload a file, send a notification, or choose whether to retry.

| Point | When |
| --- | --- |
| `onSitemapJobQueued` | A job was accepted |
| `onSitemapJobStarted` | A worker picked it up |
| `onSitemapJobCompleted` | The crawl finished and the file was written |
| `onSitemapJobFailed` | The crawl threw |
| `onSitemapJobInterrupted` | It was canceled, or its process died |

### What happens when the app restarts or crashes

Crawls cannot survive a stopped JVM or resume partway through. The registry
marks stopped jobs `interrupted` so callers can decide whether to run them again.

| What happened | How it is handled |
| --- | --- |
| ColdBox reinit (`?fwreinit=1`) | The module cancels its running crawls and records them as `interrupted` before the framework rebuilds |
| Server stopped, killed, or out of memory | A scheduled task finds jobs with heartbeats older than `jobStaleSeconds` and marks them `interrupted` |
| App restarted with a durable store | Startup recovery uses the boot ID to mark jobs from the earlier application start `interrupted` |

`config/Scheduler.cfc` registers three recovery tasks:

| Task | When it runs | What it does |
| --- | --- | --- |
| Startup sweep | Once, shortly after every boot | Marks jobs left `running` by this server's previous start as `interrupted`, matching on boot id |
| Heartbeat | Every `jobHeartbeatSeconds` for shared stores | Writes each running job's counters and heartbeat |
| Dead-job check | Every `jobReaperIntervalSeconds` for shared stores | Marks jobs with stale heartbeats `interrupted` |

`isShared()` must return `true` only when multiple app servers use the same
records. Otherwise, the heartbeat and dead-job tasks are disabled before they
reach the scheduler. A single server reads its live counters from memory, and
startup recovery handles records from its earlier application start. Changing
`jobStoreDsl` requires a reinit because the scheduler checks the store at load.

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

The store saves status changes and heartbeats, not every counter change. Three
methods have important requirements:

- **`isShared()`** must return `true` only when multiple app servers use the same
  records. Return `false` for a single-server durable store such as SQLite. A
  false positive schedules unnecessary heartbeat writes and stale-job queries.
  A false negative leaves another crashed server's job marked `running`.
- **`claim()`** must atomically move one job from `queued` to `running` for one
  caller. In a database, use a conditional update and check that one row changed.
  This prevents two servers from running the same job.
- **`save()`** with `expectedOwnerId` must write only when that owner still owns
  the job. This rejects a late write from a crawl thread that survived reinit.

With a durable store, your application must requeue jobs left `queued` after a
stop. It must also decide whether to retry `interrupted` jobs. Use `attempts` to
limit retries.

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

This summary is not the license. [LICENSE.md](LICENSE.md) governs use.

sitemap-spider is source-available, not open source. PolyForm Perimeter
restricts using it to compete with this module.

Copyright Angry Sam Productions, Inc.
