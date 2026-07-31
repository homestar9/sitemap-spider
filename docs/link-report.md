# Broken link reports

`sitemap-spider` can save a JSON report containing broken pages, redirects, and
skipped URLs found during a crawl.

## Create a report

Pass `writeLinkReport = true` and save the sitemap to a file:

```cfml
var result = sitemapService.create(
    url             = "https://example.com/",
    filePath        = expandPath( "/sitemap.xml" ),
    writeLinkReport = true
);

// /path/to/sitemap.xml.links.json
writeOutput( result.linkReportPath );
```

The report is saved next to the sitemap unless `linkReportPath` specifies
another location. Checking broken pages adds no HTTP requests because the
crawler already visits those URLs. Enabling `checkAssets` does add requests.

Read a saved report with:

```cfml
var report = sitemapService.readLinkReport( result.linkReportPath );
```

`readLinkReport()` accepts either the report path or the sitemap path. It
returns `{ exists : false }` when the file is missing or does not contain valid
JSON.

## Report structure

```cfml
{
    schemaVersion : 1,
    generatedAt   : "2026-07-30T09:00:00-05:00",
    site          : "https://example.com/",
    summary       : {
        checked       : 1263,
        pagesChecked  : 1247,
        assetsChecked : 16,
        broken        : 7,
        brokenAssets  : 5,
        redirected    : 31,
        skipped       : 22
    },
    broken    : [ ... ],
    redirects : [ ... ],
    skipped   : [ ... ]
}
```

`summary.checked` is the total of `pagesChecked` and `assetsChecked`.
`generatedAt` matches `result.stats.generatedAt`.

Each entry in `broken` has this shape:

```cfml
{
    url              : "https://example.com/gone.cfm",
    status           : 404,
    reason           : "notFound",
    message          : "Failed to fetch ... status code 404",
    kind             : "page",
    foundOn          : [ "https://example.com/about/" ],
    foundOnTruncated : false,
    redirectChain    : [ { url : "...", status : 301 } ]
}
```

Important details:

- `status` is `0` when the server never returned an HTTP response.
- `kind` is `"page"` or `"asset"`.
- `foundOnTruncated` is `true` when the number of referring pages exceeded
  `maxInboundLinks`.
- `badUrls` in the normal `create()` result contains the same failure details,
  but it is keyed by URL, so its values do not contain the `url` field.

### Failure reasons

| Reason | Meaning |
| --- | --- |
| `notFound` | HTTP 404 or 410. |
| `serverError` | Any HTTP 5xx response. |
| `clientError` | Any other HTTP 4xx response, such as 403. |
| `redirectError` | A redirect the browser could not follow, such as one without a `Location` header. |
| `tooManyRedirects` | The browser reached `maxRedirects`. |
| `timeout` | The request timed out. |
| `connectionFailed` | A DNS, TLS, or connection failure. |
| `unknown` | No status or recognized cause was available. |

Broken entries are sorted by severity and then URL. Redirect entries include a
`permanent` value that is `true` for HTTP 301 and 308 responses.

## Finding pages that contain a bad link

The `foundOn` array identifies pages that link to a broken or redirected URL.
The crawler discards this information after a URL succeeds without redirecting,
which limits memory use.

Disable this feature with:

```cfml
moduleSettings = {
    "sitemap-spider" : {
        trackInboundLinks : false
    }
};
```

The default `maxInboundLinks` value keeps up to 10 referring pages for each URL.

## Checking assets

By default, the report covers pages only. Enable `checkAssets` to check on-host
images, stylesheets, scripts, and linked files:

```cfml
moduleSettings = {
    "sitemap-spider" : {
        writeLinkReport : true,
        checkAssets     : true
    }
};
```

Asset checks:

- Run after the page crawl and request each unique asset once.
- Try a `HEAD` request first, then a one-byte `GET` when the server rejects
  `HEAD` with HTTP 405 or 501.
- Never add assets to `pages`, `maxPages`, or the sitemap XML.
- Ignore assets on other hosts.
- Stop at `maxAssetChecks` and log a warning.

Broken assets use `kind : "asset"` and are counted by
`summary.brokenAssets` and `result.stats.assetsBrokenCount`.

## Custom browser backends

`IBrowser` requires `fetchUrl()`, `checkUrl()`, `getText()`, `shutdown()`, and
`supportsParallel()`. Extending `BaseBrowser` provides `checkUrl()`,
`shutdown()`, and `supportsParallel()`. A custom backend must implement
`fetchUrl()` and `getText()`.

Two rules allow link reports to classify failures:

- `fetchUrl()` must throw `StatusCodeException` for a non-200 response. Put the
  HTTP status in `errorCode` and JSON containing `status`, `url`, and `chain`
  in `extendedInfo`. Without these details, the failure is reported with
  `status : 0` and `reason : "unknown"`.
- `checkUrl()` must not throw. It returns
  `{ ok, status, url, redirectChain, error }`, including when the URL cannot be
  reached.

## Storage and failure behavior

- The report does not change the generated sitemap XML.
- Store reports outside the webroot or block `*.links.json` at the web server.
  Reports can reveal failed and deliberately skipped URLs.
- A report write failure throws `sitemap-spider.LinkReportSaveFailed`.
