component accessors=true hint="Handles crawling of website URLs" {

    property name="parser" inject="Parser@sitemap-spider";
    property name="robotsParser" inject="RobotsParser@sitemap-spider";
    property name="logger" inject="logbox:logger:{this}";
    property name="settings" inject="coldbox:moduleSettings:sitemap-spider";
    property name="wirebox" inject="Wirebox";

    /**
     * Initializes the crawler
     *
     * processedUrls, queuedUrls, and excludeUrls are structs used as sets: the
     * URL is the key, so membership is an O(1) keyExists() check instead of an
     * O(n) array scan. The queue itself stays an ordered array because
     * breadth-first traversal needs FIFO order.
     */
    function init() {
        resetState();
        return this;
    }

    /**
     * Clears all per-crawl state to empty starting values.
     *
     * Called from init() and again at the top of each crawl(). Resetting per
     * crawl matters because a second crawl() on the same instance would otherwise
     * accumulate the first crawl's pages, processed URLs, and queue. The instance
     * is normally transient (a fresh one per crawl), but WireBox may hand back a
     * cached instance, so crawl() cannot assume it starts clean.
     */
    private void function resetState() {
        variables.pages = {};
        variables.processedUrls = {}; // set of URLs already crawled
        variables.queue = []; // ordered FIFO of { url, depth } still to crawl
        variables.queuedUrls = {}; // set of URLs currently in the queue
        variables.hostName = "";
        variables.excludeUrls = {}; // set of URLs explicitly excluded by the user
        variables.badUrls = {}; // urls that couldn't be fetched
        variables.disallowedUrls = {}; // set of URLs skipped because robots.txt disallows them
        // robots.txt state, (re)loaded at the start of each crawl().
        variables.robotsBasePath = "/"; // site-root path the seed URL lives under
        variables.effectiveCrawlDelay = 0; // seconds to wait between fetches (capped)
        variables.hasFetched = false; // becomes true after the first fetch, so the delay is not applied before it
    }

    function onDiComplete() {
        variables.browser = getBrowser();
    }


    private function getBrowser() {
        return wirebox.getInstance( settings.browserDsl );
    }

    /**
     * Crawls a website starting from one or more URLs
     * @urls An array of URLs to start crawling
     * @excludeUrls An array of URLs to exclude from crawling
     * @return A struct with the crawled pages, bad URLs, and processed URLs.
     *         processedUrls is returned as an array (via structKeyArray) even
     *         though it is tracked internally as a set, so callers keep a simple
     *         list shape.
     */
    struct function crawl(
        required array urls,
        required array excludeUrls
    ) {

        // Clear any state from a prior crawl on this instance (WireBox may return a
        // cached Crawler), so pages/processedUrls/queue do not accumulate.
        resetState();

        // Validate and set hostname from the first URL
        if ( arrayLen( arguments.urls ) == 0 ) {
            throw( type="InvalidArgumentException", message="At least one starting URL is required" );
        }
        variables.hostName = createObject( "java", "java.net.URL" ).init( javaCast( "string", arguments.urls[ 1 ] ) ).getHost( );
        parser.setHostName( variables.hostName );

        // Load robots.txt for the first seed URL. Sets robotsBasePath and the
        // effective crawl delay used below.
        loadRobots( arguments.urls[ 1 ] );

        // Turn the excluded-URL array into a set for O(1) membership checks.
        variables.excludeUrls = {};
        for ( var excluded in arguments.excludeUrls ) {
            variables.excludeUrls[ excluded ] = true;
        }

        // Enqueue valid URLs
        arguments.urls.each( function( url ) {

            logger.info( "CRAWLING:" & arguments.url );

            if ( shouldEnqueue( arguments.url ) ) {
                enqueue( arguments.url, 0 );
            } else {
                logger.warn( "Invalid or non-matching URL skipped: #arguments.url#" );
            }
        } );

        // Synchronous breadth-first crawl. v1 is single-threaded; task 14
        // reintroduces parallelism with proper locking. The finally releases any
        // resources the browser holds for this crawl (the Playwright backend
        // closes its browser process here; the Jsoup backend's shutdown is a
        // no-op), even if a fetch throws out of the loop.
        try {
            while ( variables.queue.len( ) ) {
                runQueueItem();
            }
        } finally {
            browser.shutdown();
        }

        return {
            "pages": variables.pages,
            "badUrls": variables.badUrls,
            "processedUrls": structKeyArray( variables.processedUrls ),
            "disallowedUrls": structKeyArray( variables.disallowedUrls )
        };
    }

    /**
     * Fetches and parses robots.txt for the crawl, and computes the crawl delay.
     * @seedUrl The first starting URL; its scheme, host, and base path locate
     *          robots.txt and define the base that Disallow/Allow paths are
     *          matched relative to.
     *
     * robots.txt is read at <scheme>://<authority><basePath>robots.txt, where
     * basePath is the seed URL's path up to and including its last "/". Matching
     * is base-relative, so a site served under a subpath (as the sample site is)
     * can ship its own robots.txt; for a site at the host root this equals the
     * standard behavior.
     *
     * A missing or unreachable robots.txt (getText throws) or respectRobotsTxt =
     * false leaves an empty rule set, so every URL is allowed.
     */
    private void function loadRobots( required string seedUrl ) {
        var urlObj = createObject( "java", "java.net.URL" ).init( javaCast( "string", arguments.seedUrl ) );
        var path = urlObj.getPath();
        var lastSlash = path.lastIndexOf( "/" );
        variables.robotsBasePath = ( lastSlash >= 0 ) ? path.substring( 0, lastSlash + 1 ) : "/";

        var robotsContent = "";
        if ( settings.respectRobotsTxt ) {
            var port = urlObj.getPort();
            var authority = urlObj.getHost() & ( port == -1 ? "" : ":" & port );
            var robotsUrl = urlObj.getProtocol() & "://" & authority & variables.robotsBasePath & "robots.txt";
            try {
                robotsContent = browser.getText( robotsUrl );
                logger.info( "Loaded robots.txt from #robotsUrl#" );
            } catch ( any e ) {
                // 404, timeout, or any fetch error -> crawl everything.
                logger.info( "No usable robots.txt at #robotsUrl# (#e.message#); allowing all URLs" );
                robotsContent = "";
            }
        }

        robotsParser.parse( robotsContent, settings.userAgent );
        variables.effectiveCrawlDelay = min( robotsParser.getCrawlDelay(), settings.maxCrawlDelay );
    }

    /**
     * Validates a URL and checks if it matches the hostname
     * @url The URL to validate
     *
     * Delegates the "is this a crawlable URL for our host?" decision to
     * Parser.isUrlAllowed, the single owner of that rule (it checks the http/https
     * protocol, the host match, and settings.notAllowedPattern). The Crawler only
     * adds the exclusion check, because the excluded-URL set is a Crawler concern.
     */
    private boolean function isValidUrl( required string url ) {
        return parser.isUrlAllowed( arguments.url ) && !isUrlExcluded( arguments.url );
    }

    /**
     * Decides whether a URL should be enqueued, and records the reason when not.
     * @url The URL to check
     *
     * A URL is enqueued only when it is a valid crawlable URL (isValidUrl) and
     * robots.txt allows it. A URL that is valid but robots-disallowed is added to
     * the disallowedUrls set so the caller can see what robots blocked. This is
     * the single gate the seed loop and the link loop both call, so a disallowed
     * URL is recorded once per crawl (the set de-duplicates repeats).
     */
    private boolean function shouldEnqueue( required string url ) {
        if ( !isValidUrl( arguments.url ) ) {
            return false;
        }
        if ( !isAllowedByRobots( arguments.url ) ) {
            appendDisallowedUrl( arguments.url );
            return false;
        }
        return true;
    }

    /**
     * Checks robots.txt for a URL by matching its path relative to the crawl base.
     * @url The URL to check
     *
     * Converts the URL to a site-root-relative path (its path with robotsBasePath
     * removed and a leading "/" restored), then asks the RobotsParser. A URL whose
     * path does not sit under the base is checked by its full path. When
     * respectRobotsTxt is false, the rule set is empty so this always returns true.
     */
    private boolean function isAllowedByRobots( required string url ) {
        try {
            var urlPath = createObject( "java", "java.net.URL" ).init( javaCast( "string", arguments.url ) ).getPath();
        } catch ( any e ) {
            // A URL java.net.URL cannot parse is left to the other filters; treat
            // it as allowed here rather than throwing from the enqueue path.
            return true;
        }
        var relativePath = urlPath.startsWith( variables.robotsBasePath )
            ? "/" & urlPath.substring( len( variables.robotsBasePath ) )
            : urlPath;
        return robotsParser.isPathAllowed( relativePath );
    }

    /**
     * Processes a single queue item
     */
    private void function runQueueItem( ) {
        var current = dequeue();
        if ( !isNull( current ) ) {
            crawlUrl( current.url, current.depth );
        }
    }

    /**
     * Crawls a single URL
     * @url The URL to crawl
     * @depth The current crawl depth
     */
    private void function crawlUrl( required string url, required numeric depth ) {
        if (
            depth > settings.maxDepth ||
            structCount( variables.pages ) >= settings.maxPages
        ) {
            return;
        }

        // Normalize URL (trim, strip fragment, collapse double slashes). cleanUrl
        // is the single owner of URL-string normalization; see Parser.cleanUrl.
        var normalizedUrl = parser.cleanUrl( arguments.url );

        if ( !len( normalizedUrl ) ) {
            return;
        }

        // Check if URL was already processed
        if ( isUrlProcessed( normalizedUrl ) ) {
            return;
        }

        logger.info( "Crawling #normalizedUrl# at depth #arguments.depth#" );

        // always add the normalized url to the processed list
        appendProcessedUrl( normalizedUrl );

        // Honor the robots.txt Crawl-delay: wait between fetches, but not before
        // the first one. Applied here (right before the fetch) rather than per
        // loop iteration, so items that return early above do not trigger a wait.
        if ( variables.effectiveCrawlDelay > 0 && variables.hasFetched ) {
            sleep( variables.effectiveCrawlDelay * 1000 );
        }
        variables.hasFetched = true;

        // Fetch the url.
        try {
            var fetchResult = browser.fetchUrl( normalizedUrl );
        } catch ( any e ) {
            logger.error( "Error fetching #arguments.url#: #e.message#, Detail: #e.detail#" );
            appendBadUrl( normalizedUrl, e.message );
            return;
        }

        // assert: we have a successful fetch
        var canonicalUrl = "";
        var links = [];
        var lastModified = "";
        var priority = getPriority( depth );

        // jsoup follows HTTP 30x, so fetchResult.url is the final URL and may
        // differ from normalizedUrl. Fall back to normalizedUrl for a browser or
        // result that does not set it.
        var fetchedUrl = ( fetchResult.keyExists( "url" ) && len( fetchResult.url ) )
            ? parser.cleanUrl( fetchResult.url )
            : normalizedUrl;

        // if we have HTML content, parse it, and extract links and canonical URL
        if ( fetchResult.keyExists( "html" ) ) {

            var parsedPage = parser.parseHtml( fetchResult.html );
            // let's determine the canonical URL, links
            canonicalUrl = parser.getCanonicalUrl( fetchResult, parsedPage );
            // extract links from the parsed page
            links = parser.getLinks( parsedPage );
            // determine the last modified date
            lastModified = parser.getLastModified( fetchResult, parsedPage );

            logger.info( "Parsed HTML content. Canonical URL: #canonicalUrl#, Links found: #links.len()#" );

            // If the page is a meta-refresh interstitial, do not record it. Enqueue
            // the target instead and stop here. normalizedUrl is already in the
            // processed set (marked before the fetch), so this page is not
            // re-crawled or indexed. The target keeps the same depth because it
            // replaces this page rather than being a child link of it.
            var metaRefreshUrl = parser.getMetaRefreshUrl( parsedPage, fetchedUrl );
            if ( len( metaRefreshUrl ) && metaRefreshUrl != normalizedUrl ) {
                logger.info( "Meta-refresh redirect: #normalizedUrl# -> #metaRefreshUrl#" );
                if ( shouldEnqueue( metaRefreshUrl ) ) {
                    enqueue( metaRefreshUrl, depth );
                }
                return;
            }

        } else {
            // if we don't have HTML content, we can still extract the canonical URL from headers
            canonicalUrl = parser.getCanonicalUrl( fetchResult );
            // and the last modified date from headers
            lastModified = parser.getLastModified( fetchResult );
        }

        // The page is recorded under the canonical URL if it declares one, else
        // under the final URL jsoup landed on after any HTTP redirect, else the URL
        // we asked for. Canonical wins because it is the site's own authoritative
        // choice. resolveEffectiveUrl runs the shared dedupe checks and signals
        // whether to skip recording this page.
        var effectiveUrl = len( canonicalUrl ) ? canonicalUrl : fetchedUrl;
        var resolved = resolveEffectiveUrl( normalizedUrl, effectiveUrl );
        if ( resolved.skip ) {
            return;
        }

        // append the page to our sitemap
        appendPage(
            url = resolved.url,
            lastModified = ( isDate( lastModified ) ? lastModified : now() ),
            priority = priority,
            depth = depth
        );

        // loop through the links and enqueue
        for ( var link in links ) {
            if ( shouldEnqueue( link ) ) {
                enqueue( link, depth + 1 );
            }
        }

    }

    /**
     * Resolves the URL a fetched page should be recorded under, and runs the
     * dedupe checks shared by canonical URLs and followed HTTP redirects.
     * @normalizedUrl The URL the crawler requested (already cleaned).
     * @effectiveUrl The canonical or post-redirect URL the page really belongs to.
     *
     * When effectiveUrl is empty or equals normalizedUrl, the page is recorded
     * as-is. When it differs, the page is really "that other URL": it is validated,
     * checked against robots.txt, and checked against the processed set. Returns a
     * struct { url, skip }. skip is true when the effective URL is invalid,
     * robots-disallowed (recorded in disallowedUrls), or already processed, in
     * which case the caller must stop and not record the page. Otherwise the
     * effective URL is added to the processed set so a later link to it is deduped.
     */
    private struct function resolveEffectiveUrl( required string normalizedUrl, required string effectiveUrl ) {
        if ( !len( arguments.effectiveUrl ) || arguments.effectiveUrl == arguments.normalizedUrl ) {
            return { "url": arguments.normalizedUrl, "skip": false };
        }
        if ( !isValidUrl( arguments.effectiveUrl ) ) {
            logger.warn( "Invalid effective URL: #arguments.effectiveUrl# for #arguments.normalizedUrl#" );
            return { "url": arguments.effectiveUrl, "skip": true };
        }
        if ( !isAllowedByRobots( arguments.effectiveUrl ) ) {
            logger.info( "Effective URL disallowed by robots.txt: #arguments.effectiveUrl# for #arguments.normalizedUrl#" );
            appendDisallowedUrl( arguments.effectiveUrl );
            return { "url": arguments.effectiveUrl, "skip": true };
        }
        if ( isUrlProcessed( arguments.effectiveUrl ) ) {
            logger.info( "Effective URL already processed: #arguments.effectiveUrl# for #arguments.normalizedUrl#" );
            return { "url": arguments.effectiveUrl, "skip": true };
        }
        appendProcessedUrl( arguments.effectiveUrl );
        return { "url": arguments.effectiveUrl, "skip": false };
    }

    private void function appendPage(
        required string url,
        required date lastModified,
        required numeric priority,
        required numeric depth
    ) {
        variables.pages[ arguments.url ] = {
            "lastModified": arguments.lastModified,
            "priority": arguments.priority,
            "depth": arguments.depth
        }

    }

    /**
     * Records a URL as crawled by adding it to the processedUrls set.
     * @url The URL to mark as processed
     */
    private void function appendProcessedUrl( required string url ) {
        variables.processedUrls[ arguments.url ] = true;
    }

    /**
     * Enqueues a URL for crawling
     * @url The URL to enqueue
     * @depth The crawl depth
     *
     * Adds the URL to both the ordered queue array and the queuedUrls set. The
     * crawl is single-threaded, so no lock is needed. A URL is enqueued only if
     * it is not already queued and has not already been processed.
     */
    private void function enqueue( required string url, required numeric depth ) {
        if (
            !isUrlQueued( arguments.url ) &&
            !isUrlProcessed( arguments.url )
        ) {
            logger.info( "ENQUEUE: #arguments.url# with depth #arguments.depth#" );
            variables.queue.append( {
                url = arguments.url,
                depth = arguments.depth
            } );
            variables.queuedUrls[ arguments.url ] = true;
        }
    }

    /**
     * Dequeues the next URL from the front of the queue (FIFO).
     * Removes the URL from the queuedUrls set and returns its { url, depth }
     * struct, or null when the queue is empty.
     */
    private any function dequeue() {
        if ( variables.queue.len() ) {
            var current = variables.queue[ 1 ];
            variables.queue.deleteAt( 1 );
            variables.queuedUrls.delete( current.url );
            return current;
        }
        return javaCast( "null", 0 );
    }

    /**
     * Checks if a URL is currently in the queue
     * @url The URL to check
     */
    private boolean function isUrlQueued( required string url ) {
        return variables.queuedUrls.keyExists( arguments.url );
    }

    /**
     * Check if URL was already processed
     * @url URL to check
     */
    private boolean function isUrlProcessed( required string url ) {
        return variables.processedUrls.keyExists( arguments.url );
    }

    /**
     * Check if URL was excluded by the caller
     * @url URL to check
     */
    private boolean function isUrlExcluded( required string url ) {
        return variables.excludeUrls.keyExists( arguments.url );
    }

    private function getPriority( required numeric depth ) {
        // Clamp to a 0.1 floor. At maxDepth (default 10) the raw value reaches 0.0,
        // and a higher maxDepth would go negative; sitemaps.org allows 0.0-1.0 but
        // 0.1 keeps deep pages minimally prioritized rather than "ignore me".
        return max( 0.1, settings.priority - ( settings.priorityDecrement * arguments.depth ) );
    }

    private void function appendBadUrl( required string url, required string message ) {
        variables.badUrls[ arguments.url ] = {
            "message": arguments.message
        };
    }

    /**
     * Records a URL skipped because robots.txt disallows it, by adding it to the
     * disallowedUrls set (so repeats from multiple pages are recorded once).
     * @url The disallowed URL
     */
    private void function appendDisallowedUrl( required string url ) {
        variables.disallowedUrls[ arguments.url ] = true;
    }

}