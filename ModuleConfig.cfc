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
	 * Events SitemapJobRegistry fires as a background job moves through its life.
	 * A host app listens to these to do its own work without this module having to
	 * know about it — uploading the finished file over FTP or SSH, emailing a
	 * customer, recording usage, or deciding whether to re-queue an interrupted
	 * job. Every listener receives { jobId, record }.
	 *
	 * Announcing an event nobody listens for does nothing, so apps that only call
	 * SitemapService directly are unaffected.
	 */
	variables.interceptorSettings = {
		customInterceptionPoints : "onSitemapJobQueued,onSitemapJobStarted,onSitemapJobCompleted,onSitemapJobFailed,onSitemapJobInterrupted"
	};

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
            // Background-job settings (SitemapJobRegistry). A host queues crawls
            // with registry.queue(), then polls getJob()/listJobs() for progress.
            //
            // jobStoreDsl: WireBox DSL of the IJobStore that holds job records. The
            //   default keeps them in memory (lost on a server restart or reinit).
            //   Point this at a durable IJobStore to keep records across restarts.
            //   The store also reports, through its isShared() method, whether more
            //   than one app server reads the same records. That answer decides
            //   whether the two background timers below run at all: with the default
            //   store they never do, because neither can accomplish anything for a
            //   single server.
            jobStoreDsl : "InMemoryJobStore@sitemap-spider",
            // maxConcurrentJobs: how many queued crawls run at once. It is the size
            //   of the registry's fixed thread pool; extra jobs wait as "queued"
            //   and auto-start as slots free. Each running job crawls
            //   single-threaded by default, so the live thread count stays near
            //   this number. Raising it, or opting jobs into runAsync, multiplies
            //   threads (maxConcurrentJobs * asyncMaxThreads worst case) — keep
            //   that within the engine's thread pool.
            maxConcurrentJobs : 3,
            // maxRetainedJobs: cap on finished records kept in the store. The
            //   oldest are evicted past this, so a long-running host does not
            //   accumulate job records forever.
            maxRetainedJobs : 100,
            // jobNodeId: names this app server in job records. Leave empty to use
            //   the machine's host name. Only matters when more than one server
            //   shares one job store: the boot sweep uses it to tell its own
            //   leftover jobs from another server's live ones.
            jobNodeId : "",
            // The next four only apply when the job store reports isShared() true.
            // With the default in-memory store the tasks they configure never run,
            // so changing these does nothing until jobStoreDsl points at a store
            // several app servers share.
            //
            // jobHeartbeatSeconds: how often a running job writes its counters and
            //   a "still alive" timestamp to the store. This is what lets a
            //   dashboard show progress for a job running elsewhere, and what the
            //   stale check reads to notice a job whose process died.
            jobHeartbeatSeconds : 30,
            // jobStaleSeconds: how old a job's last heartbeat must be before it is
            //   treated as dead and marked interrupted. Keep it several times
            //   jobHeartbeatSeconds so a slow garbage collection pause never kills
            //   a healthy job.
            jobStaleSeconds : 180,
            // jobReaperEnabled: a second off-switch for the task that marks dead
            //   jobs interrupted, on top of the store's own isShared() answer.
            //   Setting it false stops that task even on a shared store, for a host
            //   where something outside the app handles cleanup. Setting it true
            //   does not switch the task on for an unshared store.
            jobReaperEnabled : true,
            // jobReaperIntervalSeconds: how often that cleanup task runs. Worst-case
            //   time to notice a dead job is this plus jobStaleSeconds.
            jobReaperIntervalSeconds : 120,
            respectRobotsTxt : true, // fetch and honor robots.txt Disallow/Allow rules
            // When true (default), a page carrying <meta name="robots" content="noindex">
            // or an X-Robots-Tag: noindex response header is left out of the
            // sitemap. Its links are still followed (noindex is not nofollow);
            // the page lands in the result's ignored list with reason "noindex".
            // false lists such pages anyway.
            respectNoIndex : true,
            userAgent : "sitemap-spider", // matched against robots User-agent groups and sent on fetches
            maxCrawlDelay : 10, // cap (seconds) on the robots Crawl-delay actually applied between fetches
            notAllowedPattern : "\.(png|webp|svg|gif|js|css|jpg|jpeg)$|javascript:|mailto:|tel:",
            // Regex for whole-section excludes, matched case-insensitively against
            // the full URL. A match skips the URL, which is then reported in the
            // crawl result's "ignored" list with reason "excluded". Empty means no
            // pattern exclusion. This is separate from the per-crawl excludeUrls
            // argument, which is an exact whole-URL match. Example:
            // "/admin(?:/|\?|$)" covers /admin, its query form, and descendants
            // without also matching /administrator. The SitemapService.create(
            // excludePattern = ) argument overrides this for a single crawl.
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
            // When true and create() is given a filePath, a JSON "sidecar" file
            // is written next to the sitemap (metadataPath relocates it) holding
            // the stats struct, the options the crawl ran with, and the module
            // version, so a host can show "last generated" stats via
            // readMetadata() without keeping job records. Off by default so
            // nothing new appears on disk without being asked for.
            writeMetadata : false,
            // Full default path for the metadata sidecar. Empty derives the
            // sidecar name from filePath and writes it beside the sitemap. Set
            // this to a path outside the webroot to keep metadata private.
            // A create()/queue() metadataPath argument overrides this setting;
            // passing an explicit empty string forces adjacent-file derivation.
            metadataPath : "",
            // When true, the sidecar also carries the full badUrls and ignored
            // lists, not just their counts. Off by default: the sidecar's
            // default spot is the webroot next to sitemap.xml, where anyone can
            // download it.
            metadataIncludeUrls : false,
            // Format of the <lastmod> element. "date" writes the date-only W3C
            // form (YYYY-MM-DD), the default. "datetime" writes the full W3C
            // timestamp (YYYY-MM-DDThh:mm:ss+HH:MM) in the server's local
            // timezone, for pages with a precise known modification time.
            lastModFormat : "date",
            // When true, each crawled page's <img src> images are collected and
            // emitted as <image:image> entries, and the <urlset> gains the image
            // namespace. false leaves images out and keeps the output unchanged.
            // The SitemapService.create( includeImages = ) argument overrides
            // this for a single crawl, in either direction.
            includeImages : false,
            // When true, each page's <link rel="alternate" hreflang="..."> tags
            // are collected and emitted as <xhtml:link> entries, and the
            // <urlset> gains the xhtml namespace. Alternates are emitted exactly
            // as declared, including ones on other hosts. false keeps the
            // output unchanged. The SitemapService.create( includeHreflang = )
            // argument overrides this for a single crawl.
            includeHreflang : false,
            // When true, each page's videos are collected and emitted as
            // <video:video> blocks, and the <urlset> gains the video namespace.
            // Three sources are read: JSON-LD VideoObject blocks first, then
            // Open Graph og:video tags, then <video> elements. A video is only
            // emitted when it has the fields Google requires: a thumbnail,
            // title, description, and a content or player URL. false keeps the
            // output unchanged. The SitemapService.create( includeVideos = )
            // argument overrides this for a single crawl.
            includeVideos : false,
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
	 * Stops background sitemap jobs before the module goes away.
	 *
	 * ColdBox calls this on a framework reinit. Rebuilding the framework replaces
	 * every singleton, so the new SitemapJobRegistry would have no idea the old
	 * one's crawls exist. This asks the registry to stop them and write them down
	 * as interrupted, so a host sees "interrupted" (and can retry) instead of jobs
	 * stuck on "running" forever.
	 *
	 * Everything is wrapped in a try/catch on purpose. An error thrown out of
	 * onUnload() travels up and makes ColdBox delete the whole application, so a
	 * hiccup shutting jobs down must never be allowed to escape.
	 *
	 * This does not cover a server stop or a crash — no code runs then. The
	 * registry's stale-job check handles those the next time the app starts.
	 */
	function onUnload(){
		try {
			wireBox.getInstance( "SitemapJobRegistry@sitemap-spider" ).shutdown();
		} catch ( any e ) {
			// Nowhere to report this but the log; see above for why it cannot rethrow.
			if ( structKeyExists( variables, "log" ) ) {
				log.error( "sitemap-spider: error shutting down sitemap jobs: #e.message#", e );
			}
		}
	}

}
