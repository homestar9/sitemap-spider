component accessors=true hint="Handles crawling of website URLs" {

    property name="parser" inject="Parser@sitemap-spider";
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
        variables.pages = {};
        variables.processedUrls = {}; // set of URLs already crawled
        variables.queue = []; // ordered FIFO of { url, depth } still to crawl
        variables.queuedUrls = {}; // set of URLs currently in the queue
        variables.hostName = "";
        variables.excludeUrls = {}; // set of URLs explicitly excluded by the user
        variables.badUrls = {}; // urls that couldn't be fetched
        return this;
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

        // Validate and set hostname from the first URL
        if ( arrayLen( arguments.urls ) == 0 ) {
            throw( type="InvalidArgumentException", message="At least one starting URL is required" );
        }
        variables.hostName = createObject( "java", "java.net.URL" ).init( javaCast( "string", arguments.urls[ 1 ] ) ).getHost( );
        parser.setHostName( variables.hostName );

        // Turn the excluded-URL array into a set for O(1) membership checks.
        variables.excludeUrls = {};
        for ( var excluded in arguments.excludeUrls ) {
            variables.excludeUrls[ excluded ] = true;
        }

        // Enqueue valid URLs
        arguments.urls.each( function( url ) {

            logger.info( "CRAWLING:" & arguments.url );

            if ( isValidUrl( arguments.url ) ) {
                enqueue( arguments.url, 0 );
            } else {
                logger.warn( "Invalid or non-matching URL skipped: #arguments.url#" );
            }
        } );

        // Synchronous breadth-first crawl. v1 is single-threaded; task 14
        // reintroduces parallelism with proper locking.
        while ( variables.queue.len( ) ) {
            runQueueItem();
        }

        return {
            "pages": variables.pages,
            "badUrls": variables.badUrls,
            "processedUrls": structKeyArray( variables.processedUrls )
        };
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

        } else {
            // if we don't have HTML content, we can still extract the canonical URL from headers
            canonicalUrl = parser.getCanonicalUrl( fetchResult );
            // and the last modified date from headers
            lastModified = parser.getLastModified( fetchResult );
        }

        // if the canonical URL has a value and is different than the normalizedURL, perform some checks
        if ( 
            len( canonicalUrl ) && 
            canonicalUrl != normalizedUrl
        ) {

            // if the canonical URL is invalid, log a warning and skip
            if ( !isValidUrl( canonicalUrl ) ) {
                logger.warn( "Invalid canonical URL: #canonicalUrl# for #normalizedUrl#" );
                return;
            }

            // if the canonical URL is already processed, skip it.
            // we only make this check if the canonical URL is different from the normalized URL
            if ( isUrlProcessed( canonicalUrl ) ) {
                logger.info( "Canonical URL already processed: #canonicalUrl# for #normalizedUrl#" );
                return;
            }

            // append the canonical URL to the processed list
            appendProcessedUrl( canonicalUrl );

        }

        // append the page to our sitemap
        appendPage( 
            url = ( len( canonicalUrl ) ? canonicalUrl : normalizedUrl ),
            lastModified = ( isDate( lastModified ) ? lastModified : now() ),
            priority = priority,
            depth = depth
        );

        // loop through the links and enqueue
        for ( var link in links ) {
            if ( isValidUrl( link ) ) {
                enqueue( link, depth + 1 );
            }
        }

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

}