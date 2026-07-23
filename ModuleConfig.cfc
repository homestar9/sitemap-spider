/**
 * Copyright Since 2005 ColdBox Framework by Luis Majano and Ortus Solutions, Corp
 * www.ortussolutions.com
 * ---
 */
component {

	// Module Properties
	this.title 				= "sitemap-spider";
	this.author 			= "Angry Sam Productions";
	this.webURL 			= "https://www.angrysam.com";
	this.description 		= "A ColdBox Module to crawl websites and generate sitemaps.";
	this.version 			= "@build.version@+@build.number@";

	// Model Namespace
	this.modelNamespace		= "sitemap-spider";

	// CF Mapping
	this.cfmapping			= "sitemap-spider";

	// Dependencies
	this.dependencies 		= [ "cbjavaloader" ];

	/**
	 * Configure Module
	 */
	function configure(){
        // Module Settings
		variables.settings = {
            libPath : modulePath & "/lib",
            browserDsl : "Jsoup@sitemap-spider",
            maxDepth : 10,
            maxPages : 1000,
            // Default crawl mode. false = single-threaded. When true, and the
            // browser backend is parallel-safe and no robots Crawl-delay applies,
            // the crawl fetches URLs on asyncMaxThreads worker threads. A caller
            // can override this per crawl via SitemapService.create( runAsync = ).
            runAsync : false,
            asyncMaxThreads : 10, // worker count for a parallel crawl
            respectRobotsTxt : true, // fetch and honor robots.txt Disallow/Allow rules
            userAgent : "sitemap-spider", // matched against robots User-agent groups and sent on fetches
            maxCrawlDelay : 10, // cap (seconds) on the robots Crawl-delay actually applied between fetches
            notAllowedPattern : "\.(png|webp|svg|gif|js|css|jpg|jpeg)$|javascript:|mailto:|tel:",
            // Regex for whole-section excludes, matched case-insensitively against
            // the full URL. A match skips the URL, which is then reported in the
            // crawl result's "ignored" list with reason "excluded". Empty means no
            // pattern exclusion. This is separate from the per-crawl excludeUrls
            // argument, which is an exact whole-URL match. Example: "/admin/".
            excludePattern : "",
            // Query-param and ;jsessionid path-param names stripped by
            // Parser.normalizeUrl so session tokens and tracking params never
            // reach dedup keys or the sitemap. Matched case-insensitively.
            sessionParams : "cfid,cftoken,jsessionid,utm_source,utm_medium,utm_campaign,utm_term,utm_content,fbclid,gclid",
            priority : 1.0,
            priorityDecrement : 0.1, // each depth reduces priority by this much
            // sitemaps.org hard limits per sitemap file. When a crawl exceeds
            // either, SitemapService splits the output into numbered child
            // sitemaps plus a <sitemapindex>. maxUrls is the URL count; maxBytes
            // is the uncompressed file size (50 MiB).
            maxUrlsPerSitemap : 50000,
            maxSitemapBytes : 52428800,
            // When true and a filePath is given to SitemapService.create, the
            // sitemap files are written gzip-compressed with a ".gz" suffix
            // (e.g. "sitemap.xml.gz"). The protocol allows gzipped sitemaps and
            // very large sites rely on them. false writes plain XML.
            gzipOutput : false,
            // Format of the <lastmod> element. "date" writes the date-only W3C
            // form (YYYY-MM-DD), the default. "datetime" writes the full W3C
            // timestamp (YYYY-MM-DDThh:mm:ss+HH:MM) in the server's local
            // timezone, for pages with a precise known modification time.
            lastModFormat : "date",
            // When true, each crawled page's <img src> images are collected and
            // emitted as <image:image> entries, and the <urlset> gains the image
            // namespace. false leaves images out and keeps the output unchanged.
            includeImages : false,
            // What <lastmod> does when a page has no parseable Last-Modified
            // (no HTTP header, no meta tag): "omit" leaves <lastmod> out for that
            // URL (honest); "crawlTime" records the crawl timestamp instead.
            lastModFallback : "omit",
            requestTimeout : 10000, // ms
            maxBodySize : 5242880, // 5 MB cap on the response body jsoup downloads
            // Most HTTP 30x redirect hops the Jsoup backend follows for one URL
            // before giving up. It follows redirects itself (instead of letting
            // jsoup follow them silently) so it can enforce this limit and report
            // the hop chain. A URL whose chain exceeds this is recorded as bad.
            // Default 20 matches jsoup's own internal cap, so normal sites are
            // unaffected. The Playwright backend uses the browser's own limit; this
            // setting does not apply to it.
            maxRedirects : 20,
            // Playwright backend only: how long to wait for JS after navigation.
            // waitStrategy is a page load state ("load" or "networkidle");
            // waitMs is an extra fixed wait (ms) applied after, needed for content
            // injected by a setTimeout with no network activity.
            waitStrategy : "networkidle",
            waitMs : 0,
            // Playwright backend only: a CSS selector to wait for after navigation,
            // before reading the page. Use this instead of a large blanket waitMs
            // when you know which element JavaScript injects, so most fetches are
            // not slowed. Empty means no selector wait. The wait is bounded by
            // requestTimeout; a selector that never appears logs a warning and the
            // fetch continues. waitMs still applies when > 0, so the two combine.
            waitForSelector : "",
            htmlContentTypePattern : "^(text/html|application/xhtml\+xml)(;.*)?$" // check for links + canonical URLs
        };
	}

	/**
	 * Fired when the module is registered and activated.
	 */
	function onLoad(){
        //load jsoup
        wireBox.getInstance( "loader@cbjavaloader" ).appendPaths( settings.libPath );
	}

	/**
	 * Fired when the module is unregistered and unloaded
	 */
	function onUnload(){

	}

}
