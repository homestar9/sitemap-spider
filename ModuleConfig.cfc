/**
 * Copyright Since 2005 ColdBox Framework by Luis Majano and Ortus Solutions, Corp
 * www.ortussolutions.com
 * ---
 */
component {

	// Module metadata
	this.title 				= "sitemap-spider";
	this.author 			= "Angry Sam Productions";
	this.webURL 			= "https://www.angrysam.com";
	this.description 		= "A ColdBox Module to crawl websites and generate sitemaps.";
	this.version 			= "@build.version@+@build.number@";

	// WireBox model namespace
	this.modelNamespace		= "sitemap-spider";

	// CFML mapping
	this.cfmapping			= "sitemap-spider";

	// Required ColdBox modules
	this.dependencies 		= [ "cbjavaloader" ];

	// SitemapJobRegistry announces these events when a background job changes
	// state. Each listener receives { jobId, record }.
	variables.interceptorSettings = {
		customInterceptionPoints : "onSitemapJobQueued,onSitemapJobStarted,onSitemapJobCompleted,onSitemapJobFailed,onSitemapJobInterrupted"
	};

	/**
	 * configure
	 *
	 * Defines the module settings and their default values.
	 */
	function configure(){
        // Module settings
		variables.settings = {
            libPath : modulePath & "/lib",
            browserDsl : "Jsoup@sitemap-spider",
            maxDepth : 10,
            maxPages : 1000,
            // Enables parallel crawling when the browser supports it.
            // SitemapService.create( runAsync = ) can override this value.
            runAsync : false,
            asyncMaxThreads : 10, // Number of workers in a parallel crawl.
            // WireBox DSL for the IJobStore that saves background-job records.
            // The default store loses its records when the application restarts.
            jobStoreDsl : "InMemoryJobStore@sitemap-spider",
            // Limits the background crawls that can run at once. Parallel jobs
            // can use maxConcurrentJobs * asyncMaxThreads worker threads.
            maxConcurrentJobs : 3,
            // Keeps only this many completed job records.
            maxRetainedJobs : 100,
            // Identifies this app server in a shared store. Empty uses the host name.
            jobNodeId : "",
            // The next four settings apply only when IJobStore.isShared() is true.
            // Saves each running job's progress and heartbeat at this interval.
            jobHeartbeatSeconds : 30,
            // Marks a job interrupted after its heartbeat is this old. This value
            // should be several times larger than jobHeartbeatSeconds.
            jobStaleSeconds : 180,
            // Enables the task that marks stale jobs interrupted.
            jobReaperEnabled : true,
            // Checks for stale jobs at this interval.
            jobReaperIntervalSeconds : 120,
            respectRobotsTxt : true, // Honors robots.txt Allow and Disallow rules.
            // Omits pages marked noindex but continues to follow their links.
            respectNoIndex : true,
            userAgent : "sitemap-spider", // Sent with requests and matched in robots.txt.
            maxCrawlDelay : 10, // Maximum robots.txt Crawl-delay in seconds.
            notAllowedPattern : "\.(png|webp|svg|gif|js|css|jpg|jpeg)$|javascript:|mailto:|tel:",
            // Case-insensitive regex matched against the full URL. A match adds
            // the URL to ignored with reason "excluded". Empty disables it.
            excludePattern : "",
            // Parser removes these session and tracking parameters from URLs.
            sessionParams : "cfid,cftoken,jsessionid,utm_source,utm_medium,utm_campaign,utm_term,utm_content,fbclid,gclid",
            priority : 1.0,
            priorityDecrement : 0.1, // Reduces priority at each crawl depth.
            // Splits the sitemap when either sitemaps.org limit is reached.
            maxUrlsPerSitemap : 50000,
            maxSitemapBytes : 52428800, // 50 MiB before compression.
            // Compresses saved sitemap files and adds the .gz suffix.
            gzipOutput : false,
            // Saves crawl statistics and options in a JSON metadata file.
            writeMetadata : false,
            // Full metadata path. Empty saves it beside the sitemap.
            // Use a path outside the web root when the metadata must be private.
            metadataPath : "",
            // Adds the full badUrls and ignored lists to the metadata file.
            metadataIncludeUrls : false,
            // Saves broken links, redirects, and skipped URLs as JSON.
            // Only checkAssets adds requests.
            writeLinkReport : false,
            // Empty saves a .links.json report beside the sitemap.
            // Use a private path when the report must not be public.
            linkReportPath : "",
            // Records pages that contain each broken link. Successful URLs are
            // removed, so memory holds only queued and failed URLs.
            trackInboundLinks : true,
            // Linking pages kept per URL before the report marks the list capped.
            maxInboundLinks : 10,
            // Checks on-host assets without adding them to the sitemap.
            // Each asset adds an HTTP request, so this is off by default.
            checkAssets : false,
            // Limits how many unique asset URLs one crawl checks.
            maxAssetChecks : 5000,
            // Writes <lastmod> as "date" or "datetime" in the server's time zone.
            lastModFormat : "date",
            // Adds page images and the image namespace to the sitemap.
            includeImages : false,
            // Adds hreflang links and the XHTML namespace to the sitemap.
            includeHreflang : false,
            // Adds valid JSON-LD, Open Graph, and HTML video data to the sitemap.
            includeVideos : false,
            // "omit" leaves out an unknown <lastmod>. "crawlTime" uses the fetch time.
            lastModFallback : "omit",
            requestTimeout : 10000, // Milliseconds.
            maxBodySize : 5242880, // Jsoup response limit of 5 MB.
            // Limits redirects followed by Jsoup. Playwright uses its own limit.
            maxRedirects : 20,
            // Playwright load state and additional wait after navigation.
            waitStrategy : "networkidle",
            waitMs : 0,
            // Playwright waits for this selector before reading the page. Empty
            // skips the selector wait. requestTimeout limits the wait.
            waitForSelector : "",
            htmlContentTypePattern : "^(text/html|application/xhtml\+xml)(;.*)?$" // Content types that contain HTML.
        };
	}

	/**
	 * onLoad
	 *
	 * Loads the bundled jsoup jar when ColdBox activates the module.
	 */
	function onLoad(){
        // Add jsoup to the application classpath.
        wireBox.getInstance( "loader@cbjavaloader" ).appendPaths( settings.libPath );
	}

	/**
	 * onUnload
	 *
	 * Stops background jobs and marks them interrupted before a ColdBox reinit.
	 * This method must not throw because ColdBox can delete the application when
	 * a module unload handler fails.
	 */
	function onUnload(){
		try {
			wireBox.getInstance( "SitemapJobRegistry@sitemap-spider" ).shutdown();
		} catch ( any e ) {
			// Log the error but do not let it leave onUnload().
			if ( structKeyExists( variables, "log" ) ) {
				log.error( "sitemap-spider: error shutting down sitemap jobs: #e.message#", e );
			}
		}
	}

}
