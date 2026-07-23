# sitemap-spider

A ColdBox module that crawls a website and generates an XML sitemap.

It walks a site breadth-first from one or more start URLs, follows links,
honors `robots.txt`, follows redirects, and writes a
[sitemaps.org](https://www.sitemaps.org/protocol.html) `<urlset>` (or a
`<sitemapindex>` for very large sites). By default it fetches static HTML with
[jsoup](https://jsoup.org/). For pages whose links or content are rendered by
JavaScript, an optional [cbPlaywright](https://github.com/coldbox-modules/cbPlaywright)
backend renders the page in a headless browser first.

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

> Note: the test suite has been validated on Adobe 2023. Runs on Lucee 5/6 and
> BoxLang are pending — see the project tracker's deferred items.

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
| `pages` | struct | Crawled pages, keyed by URL. Each value is `{ lastModified, priority, depth }`. |
| `sitemap` | string | The primary sitemap XML. A `<urlset>` for a normal crawl, or a `<sitemapindex>` when the crawl is split. |
| `type` | string | `"single"` for one file, `"index"` when the output was split into a sitemap index plus child files. |
| `sitemaps` | array | The child sitemap files when `type` is `"index"` (each with `filename`, `xml`, and, if saved, `filePath`). Empty-ish for a single sitemap. |
| `sitemapCount` | number | Number of sitemap files: `1` for a single sitemap, otherwise the child count. |
| `duration` | number | Total crawl + generate time in milliseconds. |
| `processedUrls` | struct | Every URL the crawler visited (used to avoid re-visiting). |
| `badUrls` | array | URLs that failed to fetch or returned a non-HTML / error response. |
| `disallowedUrls` | array | URLs skipped because `robots.txt` disallowed them. |
| `ignored` | array | Links the crawl dropped, each `{ url, reason }`. `reason` is `"nofollow"`, `"excluded"` (matched `excludeUrls` or `excludePattern`), or `"disallowed"` (blocked by `robots.txt`, so these also appear in `disallowedUrls`). |
| `filePath` | string | The path passed as `filePath`, or empty when nothing was saved. |
| `saved` | boolean | `true` when the sitemap was written to `filePath`. |

Each entry in `pages` looks like:

```cfml
"https://example.com/about/" = {
    lastModified : "2026-07-01",  // date-only, or empty when unknown (see lastModFallback)
    priority     : 0.9,           // 1.0 at the start URL, reduced by depth
    depth        : 1              // link distance from the start URL
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
| `userAgent` | `"sitemap-spider"` | Sent on every fetch, and matched against `robots.txt` `User-agent` groups. |
| `maxCrawlDelay` | `10` | Upper cap, in seconds, on the `robots.txt` `Crawl-delay` actually applied between fetches. |
| `notAllowedPattern` | `\.(png\|webp\|svg\|gif\|js\|css\|jpg\|jpeg)$\|javascript:\|mailto:\|tel:` | Links matching this regex are never crawled (asset files and non-HTTP schemes). |
| `excludePattern` | `""` (empty) | Regex matched case-insensitively against the full URL for whole-section excludes (e.g. `/admin/`). A match skips the URL and reports it in `ignored` with reason `"excluded"`. Separate from the per-crawl exact-URL `excludeUrls` argument. Empty means no pattern exclusion. |
| `priority` | `1.0` | `<priority>` assigned to the start URL. |
| `priorityDecrement` | `0.1` | How much `<priority>` drops per level of depth. |
| `maxUrlsPerSitemap` | `50000` | sitemaps.org per-file URL limit. Above this the output splits into a sitemap index. |
| `maxSitemapBytes` | `52428800` | sitemaps.org per-file byte limit (50 MiB, uncompressed). Above this the output splits. |
| `lastModFallback` | `"omit"` | What `<lastmod>` does when a page has no parseable Last-Modified: `"omit"` leaves it out; `"crawlTime"` records the crawl timestamp. |
| `requestTimeout` | `10000` | Per-request timeout in milliseconds. |
| `maxBodySize` | `5242880` | Cap (bytes) on the response body a fetch downloads (5 MB). |
| `waitStrategy` | `"networkidle"` | Playwright backend only. Page load state to wait for after navigation (`"load"` or `"networkidle"`). |
| `waitMs` | `0` | Playwright backend only. Extra fixed wait (ms) after navigation, for content injected by a `setTimeout` with no network activity. |
| `libPath` | `<modulePath>/lib` | Directory cbjavaloader loads the jsoup jar from. |
| `htmlContentTypePattern` | `^(text/html\|application/xhtml\+xml)(;.*)?$` | Only responses whose content type matches are parsed for links and canonical URLs. |

## Browser backends

The `browserDsl` setting selects how each URL is fetched. Both backends share
the `IBrowser` interface in `models/browsers/`.

| Backend | `browserDsl` | Use it for |
| --- | --- | --- |
| jsoup (default) | `Jsoup@sitemap-spider` | Static HTML. Fast, no extra dependency. Links and content already present in the server-rendered HTML. |
| Playwright | `Playwright@sitemap-spider` | Pages whose links or content are added by JavaScript in the browser. Requires the optional `cbPlaywright` module. |

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

4. **Tune the wait** with `waitStrategy` and `waitMs`. `waitStrategy` is the
   page load state to wait for (`"networkidle"` by default). `waitMs` is an
   extra fixed wait applied after navigation — needed when content is injected
   by a `setTimeout` with no network activity. Note that `waitMs` applies to
   every page fetch, so a large crawl with a high `waitMs` is slow.

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

## License

PolyForm Perimeter 1.0.1. See [LICENSE.md](LICENSE.md).
