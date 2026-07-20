component accessors=true hint="Handles crawling of website URLs" {

    property name="parser" inject="Parser@sitemap-spider";
    property name="logger" inject="logbox:logger:{this}";
    property name="asyncManager" inject="asyncManager@coldbox";
    property name="settings" inject="coldbox:moduleSettings:sitemap-spider";
    property name="wirebox" inject="Wirebox";

    /**
     * Initializes the crawler
     */
    function init() {
        variables.pages = {};
        variables.processedUrls = [];
        variables.queue = [];
        variables.hostName = "";
        variables.queueLock = "";
        variables.excludeUrls = []; // explicitly excluded by the user
        variables.ignoredUrls = []; // urls ignored due to rules (e.g., nofollow)
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
     * @runAsync Whether to run asynchronously
     * @return A struct containing the crawled pages
     */
    struct function crawl( 
        required array urls, 
        required array excludeUrls, 
        required boolean runAsync 
    ) {
        
        // Validate and set hostname from the first URL
        if ( arrayLen( arguments.urls ) == 0 ) {
            throw( type="InvalidArgumentException", message="At least one starting URL is required" );
        }
        variables.hostName = createObject( "java", "java.net.URL" ).init( javaCast( "string", arguments.urls[ 1 ] ) ).getHost( );
        variables.queueLock = "sitemap-queue-" & hash( variables.hostName );
        parser.setHostName( variables.hostName );
        variables.excludeUrls = arguments.excludeUrls;

        // Enqueue valid URLs
        arguments.urls.each( function( url ) {
            
            logger.info( "CRAWLING:" & arguments.url );
            
            if ( isValidUrl( arguments.url ) ) {
                enqueue( arguments.url, 0 );
            } else {
                logger.warn( "Invalid or non-matching URL skipped: #arguments.url#" );
            }
        } );

        if ( !runAsync ) {
            while ( variables.queue.len( ) ) {
                runQueueItem();
            }
        } else {
            variables.threadPool = asyncManager.newExecutor(
                name = "sitemap-crawler",
                threads = settings.asyncMaxThreads
            );
            logger.info( "Starting async crawl with #settings.asyncMaxThreads# threads" );
            while ( variables.queue.len( ) ) {
                var batch = [ ];
                var batchSize = min( variables.queue.len( ), settings.asyncMaxThreads );
                for ( var i = 1; i <= batchSize; i++ ) {
                    batch.append( variables.threadPool.submit( ( ) => runQueueItem( ) ) );
                }
                batch.each( function( future ) {
                    future.get();
                } );
            }
        }

        return {
            "pages": variables.pages,
            "badUrls": variables.badUrls,
            "processedUrls": variables.processedUrls,
            "excludeUrls": variables.excludeUrls,
            "ignoredUrls": variables.ignoredUrls
        };
    }

    /**
     * Validates a URL and checks if it matches the hostname
     * @url The URL to validate
     */
    private boolean function isValidUrl( required string url ) {
        return (
            isValid( "url", arguments.url ) && // CF check
            isUrlHostMatch( arguments.url ) && // Same host
            isUrlAllowed( arguments.url ) &&  // allowed url type (e.g. no images, etc.)
            !isUrlExcluded( arguments.url ) // not excluded
        );
    }

    private boolean function isUrlAllowed( required string url ) {
        return reMatch( arguments.url, settings.notAllowedPattern ).len() == 0
    }

    private boolean function isUrlHostMatch( required string url ) {
        var urlObj = createObject( "java", "java.net.URL" ).init( javaCast( "string", arguments.url ) );
        return ( urlObj.getHost() == variables.hostName ); 
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
            structCount( variables.pages ) > settings.maxPages
        ) {
            return;
        }

        // Normalize URL (remove fragments)
        var normalizedUrl = normalizeUrl( arguments.url );

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

    private void function appendProcessedUrl( required string url ) {
        // TODO(task 06): switch processedUrls to a struct for O(1) lookup
        variables.processedUrls.append( arguments.url );
    }

    

    /**
     * Enqueues a URL for crawling
     * @url The URL to enqueue
     * @depth The crawl depth
     * @excludeUrls URLs to exclude from crawling
     */
    private void function enqueue( required string url, required numeric depth ) {

        lock timeout=30 type="exclusive" name=variables.queueLock {
            
            if (
                !isUrlQueued( arguments.url ) &&
                !isUrlProcessed( arguments.url )
            ) {
                logger.info( "ENQUEUE: #arguments.url# with depth #arguments.depth#" );
                variables.queue.append( {
                    url = arguments.url,
                    depth = arguments.depth
                } );
            }
        }
    }

    /**
     * Dequeues a URL from the queue
     */
    private any function dequeue() {
        lock timeout=30 type="exclusive" name=variables.queueLock {
            if ( variables.queue.len() ) {
                var current = variables.queue[ 1 ];
                variables.queue.deleteAt( 1 );
                return current;
            }
        }
        return javaCast( "null", 0 );
    }

    /**
     * Checks if a URL exists in the queue
     * @value The URL to check
     */
    private boolean function isUrlQueued( required string url ) {
        // Loop instead of queue.findNoCase( closure ) because Adobe 2023 rejects
        // the closure-predicate form of findNoCase (Lucee accepts it). == is a
        // case-insensitive string compare in CFML, matching the old behavior.
        for ( var item in variables.queue ) {
            if ( item.url == arguments.url ) {
                return true;
            }
        }
        return false;
    }

    /**
     * Normalize URL (remove fragments, preserve trailing slashes and extensions)
     * @url URL to normalize
     */
    private string function normalizeUrl( required string url ) {
        var cleaned = trim( arguments.url ); // Remove leading/trailing whitespace
        cleaned = reReplace( cleaned, "##.*$", "" ); // Remove fragments (e.g., #anchor)
        cleaned = reReplace( cleaned, "^(https?://[^/]+)//+", "\1/", "ALL" ); // Remove double slashes after protocol
        return cleaned;
    }

    /**
     * Check if URL was processed
     * @url URL to check
     */
    private boolean function isUrlProcessed( required string url ) {
        // TODO(task 06): switch processedUrls to a struct for O(1) lookup
        return !!variables.processedUrls.findNoCase( arguments.url );
    }

    private boolean function isUrlExcluded( required string url ) {
        return !!variables.excludeUrls.findNoCase( arguments.url );
    }

    private function getPriority( required numeric depth ) {
        return settings.priority - ( settings.priorityDecrement * depth );
    }

    private void function appendBadUrl( required string url, required string message ) {
        variables.badUrls[ arguments.url ] = {
            "message": arguments.message
        };
    }

}