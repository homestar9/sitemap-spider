component accessors=true hint="Handles crawling of website URLs" {

    property name="parser" inject="Parser@sitemap-spider";
    property name="robotsParser" inject="RobotsParser@sitemap-spider";
    property name="logger" inject="logbox:logger:{this}";
    property name="settings" inject="coldbox:moduleSettings:sitemap-spider";
    property name="wirebox" inject="Wirebox";

    /**
     * Initializes the crawler
     *
     * processedUrls, queuedUrls, and excludedUrls are used as sets: the URL is
     * the key, so membership is an O(1) lookup instead of an O(n) array scan.
     * processedUrls and queuedUrls are Java maps (case-sensitive keys, matching
     * the async path); excludedUrls stays a CFML struct. The queue itself stays
     * an ordered array because breadth-first traversal needs FIFO order.
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
        // The two dedup gates use Java LinkedHashMaps, not CFML structs, so their
        // keys compare with case-sensitive String.equals — the same rule the
        // async ConcurrentHashMaps use. This makes sync and async agree on which
        // URLs are fetched and enqueued (a CFML struct's case-insensitive keys
        // would merge URLs that differ only in path case, which async keeps
        // separate). initAsyncState() swaps processedUrls for a ConcurrentHashMap.
        variables.processedUrls = createObject( "java", "java.util.LinkedHashMap" ).init(); // set of URLs already crawled
        variables.queue = []; // ordered FIFO of { url, depth } still to crawl
        variables.queuedUrls = createObject( "java", "java.util.LinkedHashMap" ).init(); // set of URLs currently in the queue
        variables.hostName = "";
        variables.excludedUrls = {}; // set of URLs explicitly excluded by the user
        variables.badUrls = {}; // urls that couldn't be fetched
        variables.disallowedUrls = {}; // set of URLs skipped because robots.txt disallows them
        // robots.txt state, (re)loaded at the start of each crawl().
        variables.robotsBasePath = "/"; // site-root path the seed URL lives under
        variables.effectiveCrawlDelay = 0; // seconds to wait between fetches (capped)
        variables.hasFetched = false; // becomes true after the first fetch, so the delay is not applied before it
        // Crawl mode for this run. crawl() sets it true only when the caller asked
        // for async AND it is safe (no Crawl-delay, parallel-safe backend). The
        // state-touching helpers below branch on it: false uses the CFML structs
        // above, true uses the java.util.concurrent containers built by
        // initAsyncState(). Reset to false here so a sync crawl after an async one
        // does not read the previous run's Java containers.
        variables.async = false;
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
     * @runAsync When true, fetch URLs on several worker threads instead of one.
     *           Only honored when the crawl has no robots Crawl-delay and the
     *           browser backend reports supportsParallel(); otherwise the crawl
     *           runs single-threaded (a downgrade is logged).
     * @return A struct with the crawled pages, bad URLs, and processed URLs.
     *         processedUrls is returned as an array (its map keys) even though it
     *         is tracked internally as a set, so callers keep a simple list
     *         shape. A runAsync key reports whether the crawl actually ran in
     *         parallel.
     */
    struct function crawl(
        required array urls,
        required array excludeUrls,
        boolean runAsync = false
    ) {

        // Clear any state from a prior crawl on this instance (WireBox may return a
        // cached Crawler), so pages/processedUrls/queue do not accumulate.
        resetState();

        // Validate and set hostname from the first URL
        if ( arrayLen( arguments.urls ) == 0 ) {
            throw( type="InvalidArgumentException", message="At least one starting URL is required" );
        }
        // Lowercase the host so it matches the now-lowercased host in every
        // cleaned URL (Parser.normalizeUrl lowercases scheme + host).
        variables.hostName = lCase( createObject( "java", "java.net.URL" ).init( javaCast( "string", arguments.urls[ 1 ] ) ).getHost( ) );
        parser.setHostName( variables.hostName );

        // Load robots.txt for the first seed URL. Sets robotsBasePath and the
        // effective crawl delay used below.
        loadRobots( arguments.urls[ 1 ] );

        // Turn the excluded-URL array into a set for O(1) membership checks. Each
        // excluded URL is cleaned first so it compares against the normalized
        // crawl URLs (isUrlExcluded checks a cleaned URL); a raw exclusion would
        // otherwise never match. This set is read-only once the crawl starts, so
        // it stays a plain CFML struct even in async mode (concurrent reads are
        // safe).
        variables.excludedUrls = {};
        for ( var excluded in arguments.excludeUrls ) {
            variables.excludedUrls[ parser.cleanUrl( excluded ) ] = true;
        }

        // Decide whether this crawl runs in parallel. Async is honored only when
        // the caller asked for it AND there is no robots Crawl-delay to respect
        // (parallel fetching and a politeness delay are contradictory) AND the
        // browser backend is thread-safe. When any of those fails, run sync.
        variables.async = arguments.runAsync
            && variables.effectiveCrawlDelay == 0
            && browser.supportsParallel();

        if ( arguments.runAsync && !variables.async ) {
            logger.info(
                "runAsync requested but running single-threaded: "
                & ( variables.effectiveCrawlDelay > 0 ? "a robots Crawl-delay is in effect" : "the browser backend is not parallel-safe" )
            );
        }

        // In async mode, replace the CFML struct/array state with thread-safe
        // java.util.concurrent containers before any URL is enqueued.
        if ( variables.async ) {
            initAsyncState();
        }

        // Enqueue valid URLs. A plain for loop is used instead of urls.each() with a
        // closure: a closure captures this crawl()'s arguments scope, and on Lucee a
        // later variables-scope read inside the closure's call chain can resolve to a
        // same-named argument (the excludeUrls argument shadowed variables.excludedUrls
        // and broke isUrlExcluded). The for loop has no captured scope, so that
        // cross-engine hazard cannot happen.
        for ( var seedUrl in arguments.urls ) {

            logger.info( "CRAWLING:" & seedUrl );

            if ( shouldEnqueue( seedUrl ) ) {
                enqueue( seedUrl, 0 );
            } else {
                logger.warn( "Invalid or non-matching URL skipped: #seedUrl#" );
            }
        }

        // Drain the frontier. The finally releases any resources the browser holds
        // for this crawl (the Playwright backend closes its browser process here;
        // the Jsoup backend's shutdown is a no-op), even if a fetch throws out of
        // the loop, and in async mode only after every worker has finished.
        try {
            if ( variables.async ) {
                runAsyncCrawl();
            } else {
                while ( variables.queue.len( ) ) {
                    runQueueItem();
                }
            }
        } finally {
            browser.shutdown();
        }

        return buildCrawlResult();
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
            atMaxPages()
        ) {
            return;
        }

        // Normalize URL (trim, strip fragment, collapse double slashes). cleanUrl
        // is the single owner of URL-string normalization; see Parser.cleanUrl.
        var normalizedUrl = parser.cleanUrl( arguments.url );

        if ( !len( normalizedUrl ) ) {
            return;
        }

        // Claim this URL as processed. claimProcessed marks it and returns false
        // if another worker already did, in which case we stop so it is fetched
        // once. In async mode the mark is atomic (putIfAbsent), which is what
        // kills the old check-then-act race that let two threads fetch one URL.
        if ( !claimProcessed( normalizedUrl ) ) {
            return;
        }

        logger.info( "Crawling #normalizedUrl# at depth #arguments.depth#" );

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
        // choice. The canonical URL is cleaned here (fetchedUrl already is) so a
        // canonical with a mixed-case host or a session token is normalized
        // before the dedupe checks. resolveEffectiveUrl runs the shared dedupe
        // checks and signals whether to skip recording this page.
        var effectiveUrl = len( canonicalUrl ) ? parser.cleanUrl( canonicalUrl ) : fetchedUrl;
        var resolved = resolveEffectiveUrl( normalizedUrl, effectiveUrl );
        if ( resolved.skip ) {
            return;
        }

        // append the page to our sitemap
        // Store a real date when one was parsed, else fall back per the
        // lastModFallback setting: "crawlTime" records the crawl timestamp (old
        // behavior); "omit" (default) records "" so the generator leaves out
        // <lastmod> for this URL. Parser.getLastModified already returns a real
        // date or "", so no format guessing happens here.
        appendPage(
            url = resolved.url,
            lastModified = isDate( lastModified )
                ? lastModified
                : ( settings.lastModFallback == "crawlTime" ? now() : "" ),
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
        // Claim the effective URL. If another worker already recorded it (or it
        // was crawled directly), claimProcessed returns false and we skip so it
        // is not recorded twice.
        if ( !claimProcessed( arguments.effectiveUrl ) ) {
            logger.info( "Effective URL already processed: #arguments.effectiveUrl# for #arguments.normalizedUrl#" );
            return { "url": arguments.effectiveUrl, "skip": true };
        }
        return { "url": arguments.effectiveUrl, "skip": false };
    }

    /**
     * Records a crawled page.
     * @url The URL the page is stored under
     * @lastModified A date object, or "" when unknown
     * @priority The page priority
     * @depth The crawl depth the page was found at
     *
     * Sync mode: stores the page directly. The maxPages cutoff is already applied
     * by atMaxPages() at the top of crawlUrl, so the count stays exact.
     *
     * Async mode: reserves a slot with an atomic increment first. Several workers
     * can pass the approximate atMaxPages() check at once, so the reservation is
     * what actually caps the total: if the increment goes over maxPages the page
     * is not recorded (and the reservation is released). This keeps the recorded
     * count at most maxPages.
     */
    private void function appendPage(
        required string url,
        required any lastModified, // a date object, or "" when unknown
        required numeric priority,
        required numeric depth
    ) {
        var page = {
            "lastModified": arguments.lastModified,
            "priority": arguments.priority,
            "depth": arguments.depth
        };

        if ( variables.async ) {
            if ( variables.pageCount.incrementAndGet() > settings.maxPages ) {
                variables.pageCount.decrementAndGet();
                return;
            }
            variables.pages.put( arguments.url, page );
            return;
        }

        variables.pages[ arguments.url ] = page;
    }

    /**
     * Enqueues a URL for crawling.
     * @url The URL to enqueue
     * @depth The crawl depth
     *
     * Sync mode: adds the URL to the ordered queue array and the queuedUrls set,
     * only if it is not already queued and has not already been processed.
     *
     * Async mode: claims the URL atomically in the `seen` map. putIfAbsent returns
     * null only for the first worker to add this URL, so exactly one worker
     * enqueues it (the check-then-act race is impossible). The in-flight counter
     * is incremented BEFORE the URL is put on the frontier, so a worker can never
     * see the crawl as finished while this item exists but is not yet counted.
     */
    private void function enqueue( required string url, required numeric depth ) {
        if ( variables.async ) {
            if ( isNull( variables.seen.putIfAbsent( arguments.url, true ) ) ) {
                variables.pending.incrementAndGet();
                variables.frontier.put( {
                    url = arguments.url,
                    depth = arguments.depth
                } );
            }
            return;
        }

        if (
            !isUrlQueued( arguments.url ) &&
            !isUrlProcessed( arguments.url )
        ) {
            logger.info( "ENQUEUE: #arguments.url# with depth #arguments.depth#" );
            variables.queue.append( {
                url = arguments.url,
                depth = arguments.depth
            } );
            variables.queuedUrls.put( arguments.url, true );
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
            variables.queuedUrls.remove( current.url );
            return current;
        }
        return javaCast( "null", 0 );
    }

    /**
     * Checks if a URL is currently in the queue
     * @url The URL to check
     */
    private boolean function isUrlQueued( required string url ) {
        return variables.queuedUrls.containsKey( arguments.url );
    }

    /**
     * Check if URL was already processed. processedUrls is a java.util.Map in
     * both modes (a LinkedHashMap in sync, a ConcurrentHashMap in async), so the
     * same containsKey() call works for both. Only the sync enqueue path calls
     * this; the async path claims through claimProcessed instead.
     * @url URL to check
     */
    private boolean function isUrlProcessed( required string url ) {
        return variables.processedUrls.containsKey( arguments.url );
    }

    /**
     * Check if URL was excluded by the caller
     * @url URL to check
     */
    private boolean function isUrlExcluded( required string url ) {
        return variables.excludedUrls.keyExists( arguments.url );
    }

    private function getPriority( required numeric depth ) {
        // Clamp to a 0.1 floor. At maxDepth (default 10) the raw value reaches 0.0,
        // and a higher maxDepth would go negative; sitemaps.org allows 0.0-1.0 but
        // 0.1 keeps deep pages minimally prioritized rather than "ignore me".
        return max( 0.1, settings.priority - ( settings.priorityDecrement * arguments.depth ) );
    }

    private void function appendBadUrl( required string url, required string message ) {
        var entry = { "message": arguments.message };
        if ( variables.async ) {
            variables.badUrls.put( arguments.url, entry );
            return;
        }
        variables.badUrls[ arguments.url ] = entry;
    }

    /**
     * Records a URL skipped because robots.txt disallows it, by adding it to the
     * disallowedUrls set (so repeats from multiple pages are recorded once).
     * @url The disallowed URL
     */
    private void function appendDisallowedUrl( required string url ) {
        if ( variables.async ) {
            variables.disallowedUrls.put( arguments.url, true );
            return;
        }
        variables.disallowedUrls[ arguments.url ] = true;
    }

    /**
     * Marks a URL as processed and reports whether this call was the one that
     * claimed it. Returns true when the URL was not already processed (so the
     * caller should crawl/record it), false when it was already claimed.
     * @url The URL to claim
     *
     * processedUrls is a java.util.Map in both modes, so a single putIfAbsent
     * claims the URL either way: it returns null only for the first caller to add
     * a given key. On the async ConcurrentHashMap that is atomic (exactly one
     * worker ever gets true); on the sync LinkedHashMap it is a plain
     * check-then-set, which is safe on one thread.
     */
    private boolean function claimProcessed( required string url ) {
        return isNull( variables.processedUrls.putIfAbsent( arguments.url, true ) );
    }

    /**
     * Reports whether the crawl has reached the maxPages cap. In sync mode this is
     * exact (the page struct is only added after this returns false). In async
     * mode it reads the atomic page counter and is approximate — several workers
     * can pass it at once — so appendPage does the exact reservation.
     */
    private boolean function atMaxPages() {
        return variables.async
            ? ( variables.pageCount.get() >= settings.maxPages )
            : ( structCount( variables.pages ) >= settings.maxPages );
    }

    /**
     * Builds the thread-safe java.util.concurrent containers used for a parallel
     * crawl. Called from crawl() only when async is on, replacing the CFML
     * structs/array set up by resetState(). The frontier is a blocking queue so
     * idle workers wait for work without spinning; the maps use putIfAbsent for
     * atomic claims; the two AtomicIntegers track in-flight work (for termination)
     * and the recorded page count (for the maxPages cap).
     */
    private void function initAsyncState() {
        variables.frontier      = createObject( "java", "java.util.concurrent.LinkedBlockingQueue" ).init();
        variables.seen          = createObject( "java", "java.util.concurrent.ConcurrentHashMap" ).init();
        variables.processedUrls = createObject( "java", "java.util.concurrent.ConcurrentHashMap" ).init();
        variables.pages         = createObject( "java", "java.util.concurrent.ConcurrentHashMap" ).init();
        variables.badUrls       = createObject( "java", "java.util.concurrent.ConcurrentHashMap" ).init();
        variables.disallowedUrls = createObject( "java", "java.util.concurrent.ConcurrentHashMap" ).init();
        variables.pending       = createObject( "java", "java.util.concurrent.atomic.AtomicInteger" ).init( javaCast( "int", 0 ) );
        variables.pageCount     = createObject( "java", "java.util.concurrent.atomic.AtomicInteger" ).init( javaCast( "int", 0 ) );
    }

    /**
     * Runs the parallel crawl: starts asyncMaxThreads worker threads that each
     * drain the shared frontier, then blocks until all workers finish.
     *
     * The workers are CFML threads (the `thread` tag), not executor closures. A
     * thread body runs in this component's context, so it reads variables scope
     * and calls the private crawlUrl directly; a closure handed to a Java thread
     * pool cannot do this reliably across engines. Thread safety of the shared
     * state comes from the java.util.concurrent containers, not from the thread
     * mechanism.
     *
     * Termination uses the in-flight counter `pending`, which counts URLs that
     * have been enqueued but not yet fully processed. A worker takes an item,
     * processes it (which may enqueue children, each raising `pending`), then
     * lowers `pending` in its finally. A worker that polls an empty frontier and
     * sees `pending == 0` knows no work remains and no worker can add more, so it
     * exits. The 250 ms poll timeout bounds how long an idle worker waits before
     * re-checking, and makes the loop self-healing rather than relying on a
     * sentinel value. Each worker logs its own fetch errors so one bad page never
     * kills a worker thread.
     */
    private void function runAsyncCrawl() {
        var threadCount = max( 1, settings.asyncMaxThreads );
        // The poll timeout unit, read by each worker below. Kept in variables so
        // the thread bodies can reach it (a Java object cannot be passed as a
        // thread attribute string).
        variables.pollUnit = createObject( "java", "java.util.concurrent.TimeUnit" ).MILLISECONDS;

        // A per-crawl token keeps thread names unique. Several crawls can run in
        // one request (e.g. a test that crawls repeatedly), and reusing a thread
        // name that already ran in this request is an error on some engines.
        var runToken    = createUUID();
        var threadNames = [];
        for ( var i = 1; i <= threadCount; i++ ) {
            var threadName = "sitemap-worker-" & runToken & "-" & i;
            threadNames.append( threadName );
            thread name="#threadName#" {
                while ( true ) {
                    var item = variables.frontier.poll( javaCast( "long", 250 ), variables.pollUnit );
                    if ( isNull( item ) ) {
                        if ( variables.pending.get() == 0 ) {
                            break;
                        }
                        continue;
                    }
                    try {
                        crawlUrl( item.url, item.depth );
                    } catch ( any e ) {
                        logger.error( "Async crawl worker error on #item.url#: #e.message#", e );
                    } finally {
                        variables.pending.decrementAndGet();
                    }
                }
            }
        }

        // Block until every worker has exited, so the crawl is complete before
        // crawl()'s finally shuts the browser down.
        for ( var workerName in threadNames ) {
            thread action="join" name="#workerName#";
        }
    }

    /**
     * Builds the crawl result struct in the shape callers expect: pages and
     * badUrls as CFML structs, processedUrls and disallowedUrls as arrays, plus a
     * runAsync flag. In async mode the internal state is java.util.concurrent
     * maps, so it is copied into CFML structs/arrays here; in sync mode the state
     * is already CFML structs.
     */
    private struct function buildCrawlResult() {
        if ( variables.async ) {
            return {
                "pages": javaMapToStruct( variables.pages ),
                "badUrls": javaMapToStruct( variables.badUrls ),
                "processedUrls": javaMapKeys( variables.processedUrls ),
                "disallowedUrls": javaMapKeys( variables.disallowedUrls ),
                "runAsync": true
            };
        }
        return {
            "pages": variables.pages,
            "badUrls": variables.badUrls,
            // processedUrls is a java.util.LinkedHashMap in sync mode, so its keys
            // come out via javaMapKeys (not structKeyArray). disallowedUrls is
            // still a CFML struct in sync mode.
            "processedUrls": javaMapKeys( variables.processedUrls ),
            "disallowedUrls": structKeyArray( variables.disallowedUrls ),
            "runAsync": false
        };
    }

    /**
     * Copies a java.util.Map (a ConcurrentHashMap of URL -> value struct) into a
     * CFML struct. Iterates entrySet with an iterator, the portable pattern the
     * browser backends use for header maps.
     * @javaMap The map to copy
     */
    private struct function javaMapToStruct( required any javaMap ) {
        var out      = {};
        var iterator = arguments.javaMap.entrySet().iterator();
        while ( iterator.hasNext() ) {
            var entry = iterator.next();
            out[ entry.getKey() ] = entry.getValue();
        }
        return out;
    }

    /**
     * Returns the keys of a java.util.Map as a CFML array, so a concurrent set
     * used only for membership comes back in the same array shape sync mode
     * returns via structKeyArray.
     * @javaMap The map whose keys to collect
     */
    private array function javaMapKeys( required any javaMap ) {
        var out      = [];
        var iterator = arguments.javaMap.keySet().iterator();
        while ( iterator.hasNext() ) {
            out.append( iterator.next() );
        }
        return out;
    }

}