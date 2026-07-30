component accessors=true hint="Handles crawling of website URLs" {

    property name="parser" inject="Parser@sitemap-spider";
    property name="robotsParser" inject="RobotsParser@sitemap-spider";
    property name="logger" inject="logbox:logger:{this}";
    property name="settings" inject="coldbox:moduleSettings:sitemap-spider";
    property name="wirebox" inject="Wirebox";

    /**
     * init
     *
     * Creates an empty crawler.
     */
    function init() {
        resetState();
        return this;
    }

    /**
     * resetState
     *
     * Clears all data from the previous crawl.
     */
    private void function resetState() {
        // Keep pages in an array because CFML struct keys are case-insensitive.
        // An array preserves distinct paths such as /Page and /page.
        variables.pages = [];
        // Java maps keep URL comparisons case-sensitive in both crawl modes.
        variables.processedUrls = createObject( "java", "java.util.LinkedHashMap" ).init(); // URLs already crawled.
        variables.queue = []; // First-in, first-out list of { url, depth }.
        variables.queuedUrls = createObject( "java", "java.util.LinkedHashMap" ).init(); // URLs in the queue.
        variables.hostName = "";
        variables.excludedUrls = {}; // Exact URLs excluded by the caller.
        variables.badUrls = {}; // URLs that could not be fetched.
        // Maps each requested URL to its { url, status } redirect steps.
        variables.redirects = {};
        // Maps each skipped URL to its first skip reason.
        variables.ignoredUrls = {};
        variables.robotsBasePath = "/"; // Path used as the robots.txt rule root.
        variables.effectiveCrawlDelay = 0; // Seconds between fetches after applying the cap.
        variables.hasFetched = false; // Prevents a delay before the first synchronous fetch.
        // State helpers use thread-safe containers only when async is true.
        variables.async = false;
    }

    /**
     * onDiComplete
     *
     * Loads the default browser after WireBox finishes dependency injection.
     */
    function onDiComplete() {
        variables.browser = getBrowser();
    }

    /**
     * getBrowser
     *
     * Returns the browser selected by settings.browserDsl.
     */
    private function getBrowser() {
        return wirebox.getInstance( settings.browserDsl );
    }

    /**
     * crawl
     *
     * Crawls the starting URLs and returns the pages and crawl reports.
     *
     * @urls Starting URLs. The first URL defines the allowed host.
     * @excludeUrls Exact URLs to skip.
     * @excludePattern Case-insensitive regex matched against each full URL.
     * @runAsync Enables parallel workers when the browser supports them.
     * @progress CrawlProgress object used for counts and cancellation.
     * @browserDsl Browser backend for this crawl. Empty uses the module setting.
     * @includeImages Collects page images.
     * @includeHreflang Collects alternate-language links.
     * @includeVideos Collects video metadata.
     * @return Pages, processed URLs, bad URLs, ignored URLs, redirects, and the
     *   crawl mode that was used.
     */
    struct function crawl(
        required array urls,
        required array excludeUrls,
        string excludePattern = "",
        boolean runAsync = false,
        any progress,
        string browserDsl = "",
        boolean includeImages,
        boolean includeHreflang,
        boolean includeVideos
    ) {

        // Start with empty state even if WireBox reused this Crawler.
        resetState();

        // Always use a CrawlProgress object so helpers do not need null checks.
        variables.progress = isNull( arguments.progress )
            ? wirebox.getInstance( "CrawlProgress@sitemap-spider" )
            : arguments.progress;

        // Copy the shared settings. A concurrent crawl must not change this
        // crawl's limits or options after it starts.
        variables.settings = duplicate( variables.settings );

        // Apply the per-crawl browser override before robots.txt is fetched.
        if ( len( arguments.browserDsl ) ) {
            variables.settings.browserDsl = arguments.browserDsl;
            variables.browser = getBrowser();
        }

        // Apply only extension flags that the caller passed. isNull distinguishes
        // an omitted argument from an explicit false.
        if ( !isNull( arguments.includeImages ) ) {
            variables.settings.includeImages = arguments.includeImages;
        }
        if ( !isNull( arguments.includeHreflang ) ) {
            variables.settings.includeHreflang = arguments.includeHreflang;
        }
        if ( !isNull( arguments.includeVideos ) ) {
            variables.settings.includeVideos = arguments.includeVideos;
        }

        variables.progress.markStarted();

        // Validate the seeds and set the allowed host from the first URL.
        if ( arrayLen( arguments.urls ) == 0 ) {
            throw( type="InvalidArgumentException", message="At least one starting URL is required" );
        }
        // Parser also lowercases hosts, so store this host in lowercase.
        variables.hostName = lCase( createObject( "java", "java.net.URL" ).init( javaCast( "string", arguments.urls[ 1 ] ) ).getHost( ) );
        parser.setHostName( variables.hostName );

        // Load robots.txt rules and the crawl delay.
        loadRobots( arguments.urls[ 1 ] );

        // Normalize exact exclusions before comparing them with crawled URLs.
        variables.excludedUrls = {};
        for ( var excluded in arguments.excludeUrls ) {
            variables.excludedUrls[ parser.cleanUrl( excluded ) ] = true;
        }

        // A non-empty per-crawl pattern overrides the module setting.
        variables.excludePattern = len( arguments.excludePattern )
            ? arguments.excludePattern
            : settings.excludePattern;

        // Run in parallel only when the browser says concurrent fetches are safe.
        variables.async = arguments.runAsync && browser.supportsParallel();

        if ( arguments.runAsync && !variables.async ) {
            logger.info( "runAsync requested but running single-threaded: the browser backend is not parallel-safe" );
        }

        // Create thread-safe state before workers can enqueue URLs.
        if ( variables.async ) {
            initAsyncState();
        }

        // Use a for loop because a Lucee closure can confuse arguments.excludeUrls
        // with variables.excludedUrls inside the helper calls.
        for ( var seedUrl in arguments.urls ) {

            logger.info( "CRAWLING:" & seedUrl );

            // Add an accepted seed to the queue. Record why a rejected seed was skipped.
            var seedReason = enqueueDecision( seedUrl );
            if ( !len( seedReason ) ) {
                enqueue( seedUrl, 0 );
            } else {
                appendIgnoredUrl( seedUrl, seedReason );
                logger.warn( "Seed URL skipped (#seedReason#): #seedUrl#" );
            }
        }

        // Process the queue. Always close the browser after all workers finish.
        try {
            if ( variables.async ) {
                runAsyncCrawl();
            } else {
                // Stop between pages when canceled and report the current queue size.
                while ( variables.queue.len( ) && !variables.progress.isCanceled() ) {
                    variables.progress.setRemaining( variables.queue.len() );
                    runQueueItem();
                }
            }
        } finally {
            browser.shutdown();
            variables.progress.markEnded();
        }

        return buildCrawlResult();
    }

    /**
     * loadRobots
     *
     * Loads robots.txt rules and the capped crawl delay for the first seed.
     * Missing or unreadable robots.txt content allows every URL.
     *
     * @seedUrl First seed URL. Its directory locates robots.txt and becomes the
     *   root used to match Allow and Disallow paths.
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
                // A missing or unreadable robots.txt file allows every URL.
                logger.info( "No usable robots.txt at #robotsUrl# (#e.message#); allowing all URLs" );
                robotsContent = "";
            }
        }

        robotsParser.parse( robotsContent, settings.userAgent );
        variables.effectiveCrawlDelay = min( robotsParser.getCrawlDelay(), settings.maxCrawlDelay );
    }

    /**
     * isValidUrl
     *
     * Returns whether a URL is crawlable and not excluded.
     *
     * @url URL to check.
     */
    private boolean function isValidUrl( required string url ) {
        return parser.isUrlAllowed( arguments.url ) && !isUrlExcluded( arguments.url );
    }

    /**
     * enqueueDecision
     *
     * Returns why a URL must be skipped, or an empty string when it can be queued.
     * Reasons are "notAllowed", "excluded", and "disallowed". The first failed
     * check decides the reason.
     *
     * @url URL to check.
     */
    private string function enqueueDecision( required string url ) {
        if ( !parser.isUrlAllowed( arguments.url ) ) {
            return "notAllowed";
        }
        if ( isUrlExcluded( arguments.url ) ) {
            return "excluded";
        }
        if ( !isAllowedByRobots( arguments.url ) ) {
            appendIgnoredUrl( arguments.url, "disallowed" );
            return "disallowed";
        }
        return "";
    }

    /**
     * shouldEnqueue
     *
     * Returns whether a URL can be added to the crawl queue.
     *
     * @url URL to check.
     */
    private boolean function shouldEnqueue( required string url ) {
        return enqueueDecision( arguments.url ) == "";
    }

    /**
     * isAllowedByRobots
     *
     * Returns whether robots.txt allows an absolute URL. It matches the path
     * relative to robotsBasePath and includes the query string.
     *
     * @url Absolute URL to check.
     */
    private boolean function isAllowedByRobots( required string url ) {
        try {
            var urlObj  = createObject( "java", "java.net.URL" ).init( javaCast( "string", arguments.url ) );
            var urlPath = urlObj.getPath();
            var query   = urlObj.getQuery(); // null when absent
        } catch ( any e ) {
            // Let the other URL checks handle values java.net.URL cannot parse.
            return true;
        }
        var relativePath = urlPath.startsWith( variables.robotsBasePath )
            ? "/" & urlPath.substring( len( variables.robotsBasePath ) )
            : urlPath;
        var matchTarget = relativePath & ( isNull( query ) || !len( query ) ? "" : "?" & query );
        return robotsParser.isPathAllowed( matchTarget );
    }

    /**
     * runQueueItem
     *
     * Removes and crawls the next queued URL.
     */
    private void function runQueueItem( ) {
        var current = dequeue();
        if ( !isNull( current ) ) {
            crawlUrl( current.url, current.depth );
        }
    }

    /**
     * crawlUrl
     *
     * Fetches one URL, records its page data, and queues its links.
     *
     * @url URL to crawl.
     * @depth Current crawl depth.
     */
    private void function crawlUrl( required string url, required numeric depth ) {
        // Stop an async worker that already took an item after cancellation.
        if ( variables.progress.isCanceled() ) {
            return;
        }
        if (
            depth > settings.maxDepth ||
            atMaxPages()
        ) {
            return;
        }

        // Normalize the URL before deduplication and fetching.
        var normalizedUrl = parser.cleanUrl( arguments.url );

        if ( !len( normalizedUrl ) ) {
            return;
        }

        // Claim the URL atomically so only one worker fetches it.
        if ( !claimProcessed( normalizedUrl ) ) {
            return;
        }

        // Count only URLs claimed for a fetch, not canonical URL claims.
        variables.progress.incrementProcessed();

        // Check again because another worker may have reached maxPages.
        // appendPage() performs the final atomic limit check.
        if ( atMaxPages() ) {
            return;
        }

        logger.info( "Crawling #normalizedUrl# at depth #arguments.depth#" );

        // Apply Crawl-delay only to URLs that will be fetched.
        applyCrawlDelay();

        // Fetch the URL.
        try {
            var fetchResult = browser.fetchUrl( normalizedUrl );
        } catch ( any e ) {
            logger.error( "Error fetching #arguments.url#: #e.message#, Detail: #e.detail#" );
            appendBadUrl( normalizedUrl, e.message );
            return;
        }

        // Record HTTP redirects under the requested URL.
        if ( fetchResult.keyExists( "redirectChain" ) ) {
            appendRedirect( normalizedUrl, fetchResult.redirectChain );
        }

        // assert: fetchResult contains a successful response.
        var canonicalUrl = "";
        var links = [];
        var lastModified = "";
        var images = []; // Collected only when includeImages is true.
        var alternates = []; // Collected only when includeHreflang is true.
        var videos = []; // Collected only when includeVideos is true.
        var noIndex = false; // Set from the response's robots directives.
        var priority = getPriority( depth );

        // Use the final URL after redirects when the browser supplies it.
        var fetchedUrl = ( fetchResult.keyExists( "url" ) && len( fetchResult.url ) )
            ? parser.cleanUrl( fetchResult.url )
            : normalizedUrl;

        // Parse HTML and extract its sitemap data.
        if ( fetchResult.keyExists( "html" ) ) {

            // Use the final URL to resolve relative links without a <base> tag.
            var parsedPage = parser.parseHtml( fetchResult.html, fetchedUrl );
            // Read the canonical URL.
            canonicalUrl = parser.getCanonicalUrl( fetchResult, parsedPage );
            // Collect crawlable links and record links marked nofollow.
            var linkResult = parser.getLinks( parsedPage );
            links = linkResult.links;
            for ( var ignoredLink in linkResult.ignored ) {
                appendIgnoredUrl( ignoredLink.url, ignoredLink.reason );
            }
            // Read the last-modified value.
            lastModified = parser.getLastModified( fetchResult, parsedPage );

            // noindex omits this page but does not stop its links from being followed.
            if ( settings.respectNoIndex ) {
                noIndex = parser.isNoIndex( fetchResult, parsedPage );
            }

            // Collect optional sitemap extensions.
            if ( settings.includeImages ) {
                images = parser.getImages( parsedPage );
            }

            if ( settings.includeHreflang ) {
                alternates = parser.getAlternateLinks( parsedPage );
            }
            if ( settings.includeVideos ) {
                videos = parser.getVideos( parsedPage );
            }

            logger.info( "Parsed HTML content. Canonical URL: #canonicalUrl#, Links found: #links.len()#" );

            // Replace a meta-refresh page with its target at the same depth.
            var metaRefreshUrl = parser.getMetaRefreshUrl( parsedPage, fetchedUrl );
            if ( len( metaRefreshUrl ) && metaRefreshUrl != normalizedUrl ) {
                logger.info( "Meta-refresh redirect: #normalizedUrl# -> #metaRefreshUrl#" );
                if ( shouldEnqueue( metaRefreshUrl ) ) {
                    enqueue( metaRefreshUrl, depth );
                }
                return;
            }

        } else {
            // A non-HTML response can still provide sitemap data in its headers.
            canonicalUrl = parser.getCanonicalUrl( fetchResult );
            lastModified = parser.getLastModified( fetchResult );
            // Only X-Robots-Tag can mark a non-HTML response noindex.
            if ( settings.respectNoIndex ) {
                noIndex = parser.isNoIndex( fetchResult );
            }
        }

        // Prefer the canonical URL, then the final redirected URL, then the
        // requested URL. Normalize it before validation and deduplication.
        var effectiveUrl = len( canonicalUrl ) ? parser.cleanUrl( canonicalUrl ) : fetchedUrl;
        var resolved = resolveEffectiveUrl( normalizedUrl, effectiveUrl );
        if ( resolved.skip ) {
            return;
        }

        if ( noIndex ) {
            // Omit a noindex page but keep the links collected from it.
            appendIgnoredUrl( resolved.url, "noindex" );
        } else {
            // Add the page. Use crawl time only when lastModFallback requests it.
            appendPage(
                url = resolved.url,
                lastModified = isDate( lastModified )
                    ? lastModified
                    : ( settings.lastModFallback == "crawlTime" ? now() : "" ),
                priority = priority,
                depth = depth,
                images = images,
                alternates = alternates,
                videos = videos
            );
        }

        // Queue accepted child links and record why the others were skipped.
        for ( var link in links ) {
            var linkReason = enqueueDecision( link );
            if ( !len( linkReason ) ) {
                enqueue( link, depth + 1 );
            } else {
                appendIgnoredUrl( link, linkReason );
            }
        }

    }

    /**
     * resolveEffectiveUrl
     *
     * Validates and claims the canonical or final redirected URL for a page.
     *
     * @normalizedUrl Clean URL that the crawler requested.
     * @effectiveUrl Canonical or final URL for the fetched page.
     * @return The URL to record and a skip flag.
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
            appendIgnoredUrl( arguments.effectiveUrl, "disallowed" );
            return { "url": arguments.effectiveUrl, "skip": true };
        }
        // Claim the effective URL so it cannot be recorded twice.
        if ( !claimProcessed( arguments.effectiveUrl ) ) {
            logger.info( "Effective URL already processed: #arguments.effectiveUrl# for #arguments.normalizedUrl#" );
            return { "url": arguments.effectiveUrl, "skip": true };
        }
        return { "url": arguments.effectiveUrl, "skip": false };
    }

    /**
     * appendPage
     *
     * Adds one page to the sitemap data. A parallel crawl reserves its page slot
     * atomically so multiple workers cannot exceed maxPages.
     *
     * @url URL stored for the page.
     * @lastModified Date value, or an empty string when unknown.
     * @priority Sitemap priority.
     * @depth Crawl depth where the page was found.
     * @images Absolute image URLs.
     * @alternates Hreflang structs with hreflang and href keys.
     * @videos Video metadata structs.
     */
    private void function appendPage(
        required string url,
        required any lastModified, // a date object, or "" when unknown
        required numeric priority,
        required numeric depth,
        array images = [],
        array alternates = [],
        array videos = []
    ) {
        // Store the URL as a value so /Page and /page remain separate.
        var page = {
            "url": arguments.url,
            "lastModified": arguments.lastModified,
            "priority": arguments.priority,
            "depth": arguments.depth,
            "images": arguments.images,
            "alternates": arguments.alternates,
            "videos": arguments.videos
        };

        if ( variables.async ) {
            if ( variables.pageCount.incrementAndGet() > settings.maxPages ) {
                variables.pageCount.decrementAndGet();
                return;
            }
            // buildCrawlResult() converts the concurrent map to an array.
            variables.pages.put( arguments.url, page );
            variables.progress.incrementPages();
            return;
        }

        variables.pages.append( page );
        variables.progress.incrementPages();
    }

    /**
     * enqueue
     *
     * Adds a URL to the crawl queue when it has not already been seen.
     * Parallel workers claim the URL atomically and increment pending before
     * publishing it so another worker cannot stop the crawl too early.
     *
     * @url URL to queue.
     * @depth Crawl depth for the URL.
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
     * dequeue
     *
     * Removes and returns the next item from the synchronous queue.
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
     * isUrlQueued
     *
     * Returns whether a URL is in the synchronous queue.
     *
     * @url URL to check.
     */
    private boolean function isUrlQueued( required string url ) {
        return variables.queuedUrls.containsKey( arguments.url );
    }

    /**
     * isUrlProcessed
     *
     * Returns whether a URL was already processed.
     *
     * @url URL to check.
     */
    private boolean function isUrlProcessed( required string url ) {
        return variables.processedUrls.containsKey( arguments.url );
    }

    /**
     * isUrlExcluded
     *
     * Returns whether a URL matches an exact exclusion or excludePattern.
     *
     * @url URL to check.
     */
    private boolean function isUrlExcluded( required string url ) {
        if ( variables.excludedUrls.keyExists( arguments.url ) ) {
            return true;
        }
        return len( variables.excludePattern )
            && reFindNoCase( variables.excludePattern, arguments.url ) > 0;
    }

    /**
     * getPriority
     *
     * Returns the sitemap priority for a crawl depth with a minimum of 0.1.
     */
    private function getPriority( required numeric depth ) {
        return max( 0.1, settings.priority - ( settings.priorityDecrement * arguments.depth ) );
    }

    /**
     * appendBadUrl
     *
     * Records a URL that could not be fetched.
     *
     * @url URL that failed.
     * @message Fetch error message.
     */
    private void function appendBadUrl( required string url, required string message ) {
        variables.progress.incrementBad();
        var entry = { "message": arguments.message };
        if ( variables.async ) {
            variables.badUrls.put( arguments.url, entry );
            return;
        }
        variables.badUrls[ arguments.url ] = entry;
    }

    /**
     * appendRedirect
     *
     * Records the redirect steps for a requested URL.
     *
     * @url Clean URL that the crawler requested.
     * @chain Redirect steps with url and status keys.
     */
    private void function appendRedirect( required string url, required array chain ) {
        if ( variables.async ) {
            variables.redirects.put( arguments.url, arguments.chain );
            return;
        }
        variables.redirects[ arguments.url ] = arguments.chain;
    }

    /**
     * appendIgnoredUrl
     *
     * Records the first reason a URL was skipped.
     *
     * @url Skipped URL.
     * @reason "nofollow", "excluded", "disallowed", "noindex", or "notAllowed".
     */
    private void function appendIgnoredUrl( required string url, required string reason ) {
        if ( variables.async ) {
            variables.ignoredUrls.putIfAbsent( arguments.url, arguments.reason );
            return;
        }
        if ( !variables.ignoredUrls.keyExists( arguments.url ) ) {
            variables.ignoredUrls[ arguments.url ] = arguments.reason;
        }
    }

    /**
     * claimProcessed
     *
     * Marks a URL processed and returns true only for the first caller.
     * putIfAbsent makes the claim atomic during a parallel crawl.
     *
     * @url URL to claim.
     */
    private boolean function claimProcessed( required string url ) {
        return isNull( variables.processedUrls.putIfAbsent( arguments.url, true ) );
    }

    /**
     * atMaxPages
     *
     * Returns whether the crawl has reached maxPages. Parallel workers use this
     * as an early check; appendPage() performs the exact atomic check.
     */
    private boolean function atMaxPages() {
        return variables.async
            ? ( variables.pageCount.get() >= settings.maxPages )
            : ( arrayLen( variables.pages ) >= settings.maxPages );
    }

    /**
     * initAsyncState
     *
     * Replaces synchronous state with thread-safe queues, maps, and counters.
     */
    private void function initAsyncState() {
        variables.frontier      = createObject( "java", "java.util.concurrent.LinkedBlockingQueue" ).init();
        variables.seen          = createObject( "java", "java.util.concurrent.ConcurrentHashMap" ).init();
        variables.processedUrls = createObject( "java", "java.util.concurrent.ConcurrentHashMap" ).init();
        variables.pages         = createObject( "java", "java.util.concurrent.ConcurrentHashMap" ).init();
        variables.badUrls       = createObject( "java", "java.util.concurrent.ConcurrentHashMap" ).init();
        variables.ignoredUrls   = createObject( "java", "java.util.concurrent.ConcurrentHashMap" ).init();
        variables.redirects     = createObject( "java", "java.util.concurrent.ConcurrentHashMap" ).init();
        variables.pending       = createObject( "java", "java.util.concurrent.atomic.AtomicInteger" ).init( javaCast( "int", 0 ) );
        variables.pageCount     = createObject( "java", "java.util.concurrent.atomic.AtomicInteger" ).init( javaCast( "int", 0 ) );
        // Workers share this timestamp to apply one Crawl-delay across all fetches.
        variables.nextAllowedFetch = createObject( "java", "java.util.concurrent.atomic.AtomicLong" ).init( javaCast( "long", 0 ) );
    }

    /**
     * applyCrawlDelay
     *
     * Waits as needed to honor robots.txt Crawl-delay.
     * A synchronous crawl waits between fetches. Parallel workers atomically
     * reserve one shared fetch time so their requests remain spaced apart.
     *
     * @return Nothing. Waiting is the side effect.
     */
    private void function applyCrawlDelay() {
        if ( variables.effectiveCrawlDelay == 0 ) {
            return;
        }
        var delayMs = variables.effectiveCrawlDelay * 1000;

        if ( variables.async ) {
            var now = getTickCount();
            while ( true ) {
                var cur    = variables.nextAllowedFetch.get();
                var target = max( cur, now );
                if ( variables.nextAllowedFetch.compareAndSet( javaCast( "long", cur ), javaCast( "long", target + delayMs ) ) ) {
                    if ( target - now > 0 ) {
                        sleep( target - now );
                    }
                    return;
                }
            }
        }

        if ( variables.hasFetched ) {
            sleep( delayMs );
        }
        variables.hasFetched = true;
    }

    /**
     * runAsyncCrawl
     *
     * Runs asyncMaxThreads workers until the shared queue and pending count are
     * empty. CFML threads can call private methods reliably on every supported
     * engine. java.util.concurrent containers protect their shared state.
     */
    private void function runAsyncCrawl() {
        var threadCount = max( 1, settings.asyncMaxThreads );
        // Store the Java time unit where each CFML thread can read it.
        variables.pollUnit = createObject( "java", "java.util.concurrent.TimeUnit" ).MILLISECONDS;

        // Thread names must be unique within a request on every engine.
        var runToken    = createUUID();
        var threadNames = [];
        for ( var i = 1; i <= threadCount; i++ ) {
            var threadName = "sitemap-worker-" & runToken & "-" & i;
            threadNames.append( threadName );
            thread name="#threadName#" {
                while ( true ) {
                    // Stop taking new work after cancellation.
                    if ( variables.progress.isCanceled() ) {
                        break;
                    }
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
                        // Report URLs that are queued or still being processed.
                        variables.progress.setRemaining( variables.pending.get() );
                    }
                }
            }
        }

        // Wait for every worker before crawl() closes the browser.
        for ( var workerName in threadNames ) {
            thread action="join" name="#workerName#";
        }
    }

    /**
     * buildCrawlResult
     *
     * Returns the public crawl result shape. It converts concurrent maps to CFML
     * arrays and structs after a parallel crawl.
     */
    private struct function buildCrawlResult() {
        if ( variables.async ) {
            return {
                // Return page values instead of the internal map.
                "pages": javaMapValues( variables.pages ),
                "badUrls": javaMapToStruct( variables.badUrls ),
                "processedUrls": javaMapKeys( variables.processedUrls ),
                "ignored": buildIgnoredPairs(),
                "redirects": buildRedirectPairs(),
                "runAsync": true
            };
        }
        return {
            // Synchronous pages are already an array.
            "pages": variables.pages,
            "badUrls": variables.badUrls,
            // processedUrls uses a Java map to preserve case-sensitive keys.
            "processedUrls": javaMapKeys( variables.processedUrls ),
            "ignored": buildIgnoredPairs(),
            "redirects": buildRedirectPairs(),
            "runAsync": false
        };
    }

    /**
     * buildRedirectPairs
     *
     * Returns redirect entries with from, to, and chain keys. Order is not guaranteed.
     */
    private array function buildRedirectPairs() {
        var out = [];
        if ( variables.async ) {
            var iterator = variables.redirects.entrySet().iterator();
            while ( iterator.hasNext() ) {
                var entry = iterator.next();
                out.append( redirectPair( entry.getKey(), entry.getValue() ) );
            }
            return out;
        }
        for ( var requestedUrl in variables.redirects ) {
            out.append( redirectPair( requestedUrl, variables.redirects[ requestedUrl ] ) );
        }
        return out;
    }

    /**
     * redirectPair
     *
     * Builds one redirect report entry.
     *
     * @requestedUrl URL that the crawler requested.
     * @chain Redirect steps with url and status keys.
     */
    private struct function redirectPair( required string requestedUrl, required array chain ) {
        var finalUrl = arguments.chain.len() ? arguments.chain[ arguments.chain.len() ].url : arguments.requestedUrl;
        return { "from": arguments.requestedUrl, "to": finalUrl, "chain": arguments.chain };
    }

    /**
     * buildIgnoredPairs
     *
     * Returns ignored entries with url and reason keys. Order is not guaranteed.
     */
    private array function buildIgnoredPairs() {
        var out = [];
        if ( variables.async ) {
            var iterator = variables.ignoredUrls.entrySet().iterator();
            while ( iterator.hasNext() ) {
                var entry = iterator.next();
                out.append( { "url": entry.getKey(), "reason": entry.getValue() } );
            }
            return out;
        }
        variables.ignoredUrls.each( function( key, value ) {
            out.append( { "url": arguments.key, "reason": arguments.value } );
        } );
        return out;
    }

    /**
     * javaMapToStruct
     *
     * Copies a Java map into a CFML struct.
     *
     * @javaMap Map to copy.
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
     * javaMapKeys
     *
     * Returns the keys of a Java map as a CFML array.
     *
     * @javaMap Map whose keys are returned.
     */
    private array function javaMapKeys( required any javaMap ) {
        var out      = [];
        var iterator = arguments.javaMap.keySet().iterator();
        while ( iterator.hasNext() ) {
            out.append( iterator.next() );
        }
        return out;
    }

    /**
     * javaMapValues
     *
     * Returns the values of a Java map as a CFML array. Order is not guaranteed.
     *
     * @javaMap Map whose values are returned.
     */
    private array function javaMapValues( required any javaMap ) {
        var out      = [];
        var iterator = arguments.javaMap.values().iterator();
        while ( iterator.hasNext() ) {
            out.append( iterator.next() );
        }
        return out;
    }

}
