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
        // pages is an ordered array of page structs (each carries its own url),
        // not a struct keyed by URL. A CFML struct's keys are case-insensitive, so
        // keying pages by URL would merge two URLs that differ only in path case
        // (/Page vs /page) even though the crawl visits them separately (the dedup
        // gates are case-sensitive Java maps). An array keeps them distinct.
        // claimProcessed() already guarantees each URL is recorded once, so the
        // array never needs its own dedup. initAsyncState() swaps this for a
        // ConcurrentHashMap keyed by URL (needed for the atomic maxPages cap); its
        // values are collected back into an array in buildCrawlResult().
        variables.pages = [];
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
        // Map of requested URL -> its redirect hop chain (array of { url, status }),
        // recorded only for fetches that followed at least one HTTP redirect. A
        // CFML struct in sync; initAsyncState swaps it for a ConcurrentHashMap.
        variables.redirects = {};
        // Map of URL -> reason for URLs dropped during the crawl, surfaced in the
        // result as the "ignored" array. Reasons: "nofollow", "excluded",
        // "disallowed", "noindex" (the page's robots directives say noindex, so
        // it is crawled for links but kept out of the sitemap), and "notAllowed"
        // (off-host, wrong scheme, or asset pattern — only a rejected seed
        // produces this one; discovered links are already filtered before they
        // reach here). A CFML struct in sync; initAsyncState swaps it for a
        // ConcurrentHashMap.
        variables.ignoredUrls = {};
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
     * @excludePattern A regex for whole-section excludes, matched case-insensitively
     *           against the full URL. When passed non-empty it overrides the
     *           excludePattern module setting for this crawl only; empty falls back
     *           to the setting.
     * @runAsync When true, fetch URLs on several worker threads instead of one.
     *           Only honored when the browser backend reports supportsParallel();
     *           otherwise the crawl runs single-threaded (a downgrade is logged).
     *           A robots Crawl-delay no longer forces sync: the delay is applied
     *           as a shared per-fetch spacing across the workers (applyCrawlDelay).
     * @progress Optional CrawlProgress the crawl updates as it runs (pages found,
     *           URLs processed, bad URLs, remaining) and checks for cancellation
     *           between items. When omitted, a fresh no-op one is used, so behavior
     *           is unchanged for callers that do not track progress.
     * @browserDsl Optional WireBox DSL of the browser backend to use for this
     *           crawl only (e.g. "Playwright@sitemap-spider" for a site whose
     *           links need JavaScript). Empty falls back to the browserDsl module
     *           setting. A host running crawls for many sites needs this because
     *           the setting is global but the right backend differs per site.
     * @includeImages Collect each page's images for this crawl only. Omit the
     *           argument to use the includeImages module setting. Passing false
     *           turns collection off even when the setting is on.
     * @includeHreflang Same, for each page's hreflang alternates.
     * @includeVideos Same, for each page's videos.
     * @return A struct with the crawled pages, bad URLs, and processed URLs.
     *         processedUrls is returned as an array (its map keys) even though it
     *         is tracked internally as a set, so callers keep a simple list
     *         shape. A runAsync key reports whether the crawl actually ran in
     *         parallel.
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

        // Clear any state from a prior crawl on this instance (WireBox may return a
        // cached Crawler), so pages/processedUrls/queue do not accumulate.
        resetState();

        // The live progress object callers can poll. When none is passed, use a
        // fresh no-op one so every progress hook below runs against real atomics
        // and no null checks are needed. Kept in variables scope so the private
        // helpers (crawlUrl, appendPage, appendBadUrl) can update it.
        variables.progress = isNull( arguments.progress )
            ? wirebox.getInstance( "CrawlProgress@sitemap-spider" )
            : arguments.progress;

        // Take a private copy of the module settings for this crawl. settings is
        // one shared mutable struct injected into every instance, so without this a
        // second concurrent crawl, or a host editing settings mid-crawl, could
        // change maxPages/maxDepth/etc. out from under this run. Every settings.X
        // read below uses this snapshot. Generalizes the per-crawl excludePattern
        // override set a few lines down.
        variables.settings = duplicate( variables.settings );

        // Swap the browser backend for this crawl when the caller named one.
        // onDiComplete already resolved the one from the browserDsl setting,
        // which is global; a host crawling many sites needs a per-site choice
        // (most sites are fine with jsoup, a few need Playwright's JavaScript
        // rendering). Resolved here, before loadRobots below makes the first
        // fetch. The instance is transient, so this crawl gets its own browser.
        if ( len( arguments.browserDsl ) ) {
            variables.settings.browserDsl = arguments.browserDsl;
            variables.browser = getBrowser();
        }

        // The three sitemap extension flags, for this crawl only. false is a
        // real value for a boolean, so "did the caller pass one?" is answered
        // by isNull rather than by an empty-string sentinel the way
        // excludePattern does it. Writing the answer onto the settings snapshot
        // is all it takes: crawlUrl reads settings.includeImages and friends
        // from there.
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

        // The section-exclude regex for this crawl. A non-empty excludePattern
        // argument overrides the module setting for this run only; an empty
        // argument falls back to the setting. isUrlExcluded reads this, not the
        // setting directly, so a single crawl can exclude a section without
        // changing global config.
        variables.excludePattern = len( arguments.excludePattern )
            ? arguments.excludePattern
            : settings.excludePattern;

        // Decide whether this crawl runs in parallel. Async is honored when the
        // caller asked for it AND the browser backend is thread-safe. A robots
        // Crawl-delay no longer forces sync: applyCrawlDelay() spaces the fetches
        // across the workers so the politeness gap is still honored in parallel.
        variables.async = arguments.runAsync && browser.supportsParallel();

        if ( arguments.runAsync && !variables.async ) {
            logger.info( "runAsync requested but running single-threaded: the browser backend is not parallel-safe" );
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

            // Classify the seed once. An empty reason means enqueue it; any reason
            // means skip it AND record it in ignored, so a caller can see why a seed
            // was dropped (excluded, disallowed, or notAllowed). Without this, a
            // rejected seed was only logged and vanished from the result. A
            // disallowed seed is also recorded by enqueueDecision itself; the
            // first-reason-wins dedup in appendIgnoredUrl keeps it a single entry.
            var seedReason = enqueueDecision( seedUrl );
            if ( !len( seedReason ) ) {
                enqueue( seedUrl, 0 );
            } else {
                appendIgnoredUrl( seedUrl, seedReason );
                logger.warn( "Seed URL skipped (#seedReason#): #seedUrl#" );
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
                // Stop between items when canceled; update the "remaining" gauge
                // from the queue size so a poller sees it fall as the crawl drains.
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
     * Classifies why a URL can or cannot be enqueued, in one place.
     * @url The URL to check
     *
     * Returns "" when the URL should be enqueued, or a reason string when it must
     * be skipped:
     *   - "notAllowed": off-host, wrong protocol, or matches notAllowedPattern.
     *   - "excluded": in the caller's exact excludeUrls set, or matches the
     *     effective excludePattern (per-crawl argument or module setting).
     *   - "disallowed": robots.txt disallows it (also recorded in the ignored map
     *     right here, so a disallowed seed lands in the result even though the seed
     *     loop is the only caller that would otherwise not record it).
     *
     * This is the single decision point shared by the seed loop, shouldEnqueue
     * (meta-refresh), and the link-expansion loop, so the enqueue rule and the
     * ignored-reason reporting can never drift apart. The order matters: a URL is
     * classified by the first rule that rejects it.
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
     * Decides whether a URL should be enqueued, and records the reason when not.
     * @url The URL to check
     *
     * Thin wrapper over enqueueDecision: a URL is enqueued only when no reason
     * rejects it. A robots-disallowed URL is recorded in the ignored map by
     * enqueueDecision so the caller can see what robots blocked; the map
     * de-duplicates repeats, so a disallowed URL is recorded once per crawl.
     */
    private boolean function shouldEnqueue( required string url ) {
        return enqueueDecision( arguments.url ) == "";
    }

    /**
     * Checks robots.txt for a URL by matching its path relative to the crawl base.
     * @url The URL to check
     *
     * Converts the URL to a site-root-relative path (its path with robotsBasePath
     * removed and a leading "/" restored), appends the query string, then asks the
     * RobotsParser. A URL whose path does not sit under the base is checked by its
     * full path. The query is included so a rule like "Disallow: /*?sort=" can
     * match; robotsBasePath is stripped from the path only, never the query. When
     * respectRobotsTxt is false, the rule set is empty so this always returns true.
     */
    private boolean function isAllowedByRobots( required string url ) {
        try {
            var urlObj  = createObject( "java", "java.net.URL" ).init( javaCast( "string", arguments.url ) );
            var urlPath = urlObj.getPath();
            var query   = urlObj.getQuery(); // null when absent
        } catch ( any e ) {
            // A URL java.net.URL cannot parse is left to the other filters; treat
            // it as allowed here rather than throwing from the enqueue path.
            return true;
        }
        var relativePath = urlPath.startsWith( variables.robotsBasePath )
            ? "/" & urlPath.substring( len( variables.robotsBasePath ) )
            : urlPath;
        var matchTarget = relativePath & ( isNull( query ) || !len( query ) ? "" : "?" & query );
        return robotsParser.isPathAllowed( matchTarget );
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
        // Bail before any work when the job was canceled. Checked here too (not
        // only in the drain loops) so an async worker that already pulled an item
        // does not fetch it after cancellation.
        if ( variables.progress.isCanceled() ) {
            return;
        }
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

        // Count this URL as processed: claiming it means this worker is the one
        // that fetches it. Counted here (not inside claimProcessed, which
        // resolveEffectiveUrl also calls) so the number tracks URLs actually
        // fetched, not claims.
        variables.progress.incrementProcessed();

        // Re-check the page cap after claiming, right before the fetch. The check
        // at the top of this method can be stale in async mode (several workers
        // pass it at once when pageCount is near maxPages), so this second read
        // catches most of the workers that filled the cap while this one waited to
        // be scheduled, avoiding a wasted fetch + parse. It narrows the overshoot
        // but does not close it (the read is still not atomic with the fetch); the
        // exact cap stays on the reservation in appendPage.
        if ( atMaxPages() ) {
            return;
        }

        logger.info( "Crawling #normalizedUrl# at depth #arguments.depth#" );

        // Honor the robots.txt Crawl-delay right before the fetch. In sync mode
        // this sleeps between fetches; in async mode each worker claims a spaced
        // fetch slot so parallel crawling still respects the politeness gap.
        // Applied here (after the early-return guards) so skipped items never wait.
        applyCrawlDelay();

        // Fetch the url.
        try {
            var fetchResult = browser.fetchUrl( normalizedUrl );
        } catch ( any e ) {
            logger.error( "Error fetching #arguments.url#: #e.message#, Detail: #e.detail#" );
            appendBadUrl( normalizedUrl, e.message );
            return;
        }

        // Record the HTTP redirect chain when the browser reported one, keyed by
        // the URL we requested, so the result can show how each URL redirected.
        if ( fetchResult.keyExists( "redirectChain" ) ) {
            appendRedirect( normalizedUrl, fetchResult.redirectChain );
        }

        // assert: we have a successful fetch
        var canonicalUrl = "";
        var links = [];
        var lastModified = "";
        var images = []; // filled from the parsed page only when includeImages is on
        var alternates = []; // filled only when includeHreflang is on
        var videos = []; // filled only when includeVideos is on
        var noIndex = false; // set below from the page's robots directives
        var priority = getPriority( depth );

        // jsoup follows HTTP 30x, so fetchResult.url is the final URL and may
        // differ from normalizedUrl. Fall back to normalizedUrl for a browser or
        // result that does not set it.
        var fetchedUrl = ( fetchResult.keyExists( "url" ) && len( fetchResult.url ) )
            ? parser.cleanUrl( fetchResult.url )
            : normalizedUrl;

        // if we have HTML content, parse it, and extract links and canonical URL
        if ( fetchResult.keyExists( "html" ) ) {

            // Pass the fetched (final, post-redirect) URL as the base so jsoup
            // resolves relative hrefs in getLinks even when the page has no
            // <base href> tag. A page that does have one overrides this.
            var parsedPage = parser.parseHtml( fetchResult.html, fetchedUrl );
            // let's determine the canonical URL, links
            canonicalUrl = parser.getCanonicalUrl( fetchResult, parsedPage );
            // extract links from the parsed page. getLinks returns { links, ignored }:
            // links are the crawlable URLs; ignored are this page's nofollow drops,
            // which we record so the caller sees them in the result's ignored list.
            var linkResult = parser.getLinks( parsedPage );
            links = linkResult.links;
            for ( var ignoredLink in linkResult.ignored ) {
                appendIgnoredUrl( ignoredLink.url, ignoredLink.reason );
            }
            // determine the last modified date
            lastModified = parser.getLastModified( fetchResult, parsedPage );

            // A noindex directive (meta robots tag or X-Robots-Tag header) keeps
            // the page out of the sitemap below, but its links are still followed.
            if ( settings.respectNoIndex ) {
                noIndex = parser.isNoIndex( fetchResult, parsedPage );
            }

            // collect the page's images for an image sitemap, only when the
            // includeImages setting is on (otherwise the page struct stays
            // image-free and the output is unchanged).
            if ( settings.includeImages ) {
                images = parser.getImages( parsedPage );
            }

            // collect hreflang alternates and video metadata the same way, each
            // behind its own setting so the page struct and output stay
            // unchanged when off.
            if ( settings.includeHreflang ) {
                alternates = parser.getAlternateLinks( parsedPage );
            }
            if ( settings.includeVideos ) {
                videos = parser.getVideos( parsedPage );
            }

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
            // no parsed page here, so only the X-Robots-Tag header can say noindex
            if ( settings.respectNoIndex ) {
                noIndex = parser.isNoIndex( fetchResult );
            }
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

        if ( noIndex ) {
            // The page asked search engines not to index it, so it stays out of
            // the sitemap — but its links were extracted above and are enqueued
            // below, because noindex does not mean nofollow.
            appendIgnoredUrl( resolved.url, "noindex" );
        } else {
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
                depth = depth,
                images = images,
                alternates = alternates,
                videos = videos
            );
        }

        // loop through the links and enqueue. enqueueDecision returns "" to enqueue
        // or a reason to skip; a skipped link is recorded in ignoredUrls so the
        // caller can see it. These links are already isUrlAllowed (getLinks
        // filtered them), so "notAllowed" will not occur here.
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
     * Resolves the URL a fetched page should be recorded under, and runs the
     * dedupe checks shared by canonical URLs and followed HTTP redirects.
     * @normalizedUrl The URL the crawler requested (already cleaned).
     * @effectiveUrl The canonical or post-redirect URL the page really belongs to.
     *
     * When effectiveUrl is empty or equals normalizedUrl, the page is recorded
     * as-is. When it differs, the page is really "that other URL": it is validated,
     * checked against robots.txt, and checked against the processed set. Returns a
     * struct { url, skip }. skip is true when the effective URL is invalid,
     * robots-disallowed (recorded in the ignored map with reason "disallowed"), or
     * already processed, in which case the caller must stop and not record the
     * page. Otherwise the effective URL is added to the processed set so a later
     * link to it is deduped.
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
     * @images Array of absolute image URLs for the page (empty unless the
     *   includeImages setting is on)
     * @alternates Array of { hreflang, href } structs for the page's declared
     *   alternate-language links (empty unless the includeHreflang setting is on)
     * @videos Array of video structs (title, description, thumbnailLoc,
     *   contentLoc, playerLoc) for the page (empty unless the includeVideos
     *   setting is on)
     *
     * Sync mode: stores the page directly. The maxPages cutoff is already applied
     * by atMaxPages() at the top of crawlUrl, so the count stays exact.
     *
     * Async mode: reserves a slot with an atomic increment first. Several workers
     * can pass the approximate atMaxPages() checks at once, so the reservation is
     * what actually caps the total: if the increment goes over maxPages the page
     * is not recorded (and the reservation is released). This keeps the recorded
     * count at most maxPages exactly. The two atMaxPages() checks in crawlUrl (one
     * at entry, one right before the fetch) only reduce wasted fetches near the
     * boundary; they are not the cap.
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
        // The url is a field on the page struct, not a map key: pages is an array,
        // so two URLs that differ only in path case (/Page vs /page) both survive
        // instead of collapsing into one case-insensitive struct key.
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
            // Async keeps a ConcurrentHashMap keyed by URL for the atomic maxPages
            // reservation above; buildCrawlResult collects its values into an array.
            variables.pages.put( arguments.url, page );
            variables.progress.incrementPages();
            return;
        }

        variables.pages.append( page );
        variables.progress.incrementPages();
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
     * Check if URL was excluded, either by the caller's exact excludeUrls list or
     * by the excludePattern module setting.
     * @url URL to check
     *
     * excludeUrls is an exact, whole-URL match (the per-crawl argument). The
     * effective excludePattern (variables.excludePattern, set in crawl() from the
     * per-crawl argument or the module setting) is a regex matched with reFindNoCase
     * against the full URL, for whole-section excludes like "/admin/". An empty
     * excludePattern matches nothing, so it is skipped.
     */
    private boolean function isUrlExcluded( required string url ) {
        if ( variables.excludedUrls.keyExists( arguments.url ) ) {
            return true;
        }
        return len( variables.excludePattern )
            && reFindNoCase( variables.excludePattern, arguments.url ) > 0;
    }

    private function getPriority( required numeric depth ) {
        // Clamp to a 0.1 floor. At maxDepth (default 10) the raw value reaches 0.0,
        // and a higher maxDepth would go negative; sitemaps.org allows 0.0-1.0 but
        // 0.1 keeps deep pages minimally prioritized rather than "ignore me".
        return max( 0.1, settings.priority - ( settings.priorityDecrement * arguments.depth ) );
    }

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
     * Records the redirect hop chain for a fetched URL, keyed by the requested URL.
     * @url The URL the crawler requested (already normalized).
     * @chain The array of { url, status } hops the browser reported.
     *
     * Only called when a fetch actually followed a redirect. The key is the
     * requested URL, which is claimed once per crawl, so there is one entry per
     * source URL that redirected.
     */
    private void function appendRedirect( required string url, required array chain ) {
        if ( variables.async ) {
            variables.redirects.put( arguments.url, arguments.chain );
            return;
        }
        variables.redirects[ arguments.url ] = arguments.chain;
    }

    /**
     * Records a link dropped during the crawl in the ignoredUrls map, keyed by URL
     * with the drop reason as the value.
     * @url The dropped URL
     * @reason Why it was dropped ("nofollow", "excluded", "disallowed",
     *   "noindex", or "notAllowed" — the last only for a rejected seed)
     *
     * The first reason recorded for a URL wins: the same URL can be dropped for
     * different reasons on different pages (e.g. nofollow on one page, a normal
     * link excluded by pattern on another), and keeping the first keeps the report
     * stable. Async uses putIfAbsent so the first worker's reason is kept; sync
     * checks keyExists first to match that.
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
            : ( arrayLen( variables.pages ) >= settings.maxPages );
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
        variables.ignoredUrls   = createObject( "java", "java.util.concurrent.ConcurrentHashMap" ).init();
        variables.redirects     = createObject( "java", "java.util.concurrent.ConcurrentHashMap" ).init();
        variables.pending       = createObject( "java", "java.util.concurrent.atomic.AtomicInteger" ).init( javaCast( "int", 0 ) );
        variables.pageCount     = createObject( "java", "java.util.concurrent.atomic.AtomicInteger" ).init( javaCast( "int", 0 ) );
        // Shared next-allowed-fetch timestamp (getTickCount millis) that spaces
        // parallel fetches when a robots Crawl-delay applies. See applyCrawlDelay.
        variables.nextAllowedFetch = createObject( "java", "java.util.concurrent.atomic.AtomicLong" ).init( javaCast( "long", 0 ) );
    }

    /**
     * Waits before a fetch to honor the robots.txt Crawl-delay, if any.
     * @return nothing; the wait is the side effect.
     *
     * Does nothing when effectiveCrawlDelay is 0 (no delay, or respectRobotsTxt
     * is off).
     *
     * Sync mode: sleeps the delay between fetches, but not before the first one
     * (the hasFetched guard).
     *
     * Async mode: several workers fetch at once, so a plain per-thread sleep would
     * not space the fetches apart. Instead each worker atomically claims the next
     * fetch slot on the shared nextAllowedFetch timestamp: it reads the current
     * slot, takes the later of that slot and now, then advances the slot by delayMs
     * with a compareAndSet. The worker that wins the compareAndSet owns that slot
     * and waits until it. This spaces the real fetches delayMs apart across all
     * workers while their parse and queue work still overlaps. The first fetch goes
     * out immediately (the slot starts at 0, so its target is now).
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
                    // Stop pulling work as soon as the job is canceled. Items left
                    // in the frontier are abandoned; the join below still returns
                    // because every worker hits this same check and exits.
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
                        // Report URLs still in flight as the "remaining" gauge.
                        variables.progress.setRemaining( variables.pending.get() );
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
     * Builds the crawl result struct in the shape callers expect: pages as an
     * array of page structs (each carrying its own url), badUrls as a CFML struct,
     * processedUrls as an array, an ignored report (array of { url, reason }), a
     * redirects report (array of { from, to, chain }), plus a runAsync flag. In
     * async mode the internal state is java.util.concurrent maps, so it is copied
     * into CFML arrays/structs here; in sync mode the state is already CFML values.
     * There is no disallowedUrls key: robots-blocked URLs appear in ignored with
     * reason "disallowed".
     */
    private struct function buildCrawlResult() {
        if ( variables.async ) {
            return {
                // Async pages is a ConcurrentHashMap keyed by URL (for the atomic
                // maxPages cap); return its values as the array callers expect.
                "pages": javaMapValues( variables.pages ),
                "badUrls": javaMapToStruct( variables.badUrls ),
                "processedUrls": javaMapKeys( variables.processedUrls ),
                "ignored": buildIgnoredPairs(),
                "redirects": buildRedirectPairs(),
                "runAsync": true
            };
        }
        return {
            // Sync pages is already an array of page structs.
            "pages": variables.pages,
            "badUrls": variables.badUrls,
            // processedUrls is a java.util.LinkedHashMap in sync mode, so its keys
            // come out via javaMapKeys (not structKeyArray).
            "processedUrls": javaMapKeys( variables.processedUrls ),
            "ignored": buildIgnoredPairs(),
            "redirects": buildRedirectPairs(),
            "runAsync": false
        };
    }

    /**
     * Builds the redirect report as an array of { from, to, chain } structs from
     * the redirects map (requested URL -> hop chain). `from` is the requested URL,
     * `to` is the final URL (the chain's last hop), and `chain` is the full array
     * of { url, status } hops. redirects is a CFML struct in sync mode and a
     * ConcurrentHashMap in async mode, so each branch reads it in its own shape.
     * The order is not guaranteed and callers should not rely on it.
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
     * Builds one { from, to, chain } redirect report entry from a requested URL and
     * its hop chain. `to` is the last hop's URL, or the requested URL if the chain
     * is somehow empty.
     * @requestedUrl The URL the crawler asked for.
     * @chain The array of { url, status } hops.
     */
    private struct function redirectPair( required string requestedUrl, required array chain ) {
        var finalUrl = arguments.chain.len() ? arguments.chain[ arguments.chain.len() ].url : arguments.requestedUrl;
        return { "from": arguments.requestedUrl, "to": finalUrl, "chain": arguments.chain };
    }

    /**
     * Builds the ignored-URL report as an array of { url, reason } structs from
     * the ignoredUrls map (URL -> reason). ignoredUrls is a CFML struct in sync
     * mode and a ConcurrentHashMap in async mode, so each branch reads it in its
     * own shape. The order is not guaranteed and callers should not rely on it.
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

    /**
     * Returns the values of a java.util.Map as a CFML array. Used for the async
     * pages map (URL -> page struct), whose values are the page structs callers
     * expect as an array. The order is not guaranteed (a ConcurrentHashMap is
     * unordered), matching the rest of the async result.
     * @javaMap The map whose values to collect
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