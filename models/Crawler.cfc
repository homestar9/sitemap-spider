component accessors=true hint="Handles crawling of website URLs" {

    property name="parser" inject="Parser@sitemap-spider";
    property name="logger" inject="logbox:logger:{this}";
    property name="asyncManager" inject="asyncManager@coldbox";
    property name="jSoup" inject="javaloader:org.jsoup.Jsoup";
    property name="settings" inject="coldbox:moduleSettings:sitemap-spider";

    /**
     * Initializes the crawler
     */
    function init() {
        variables.pages = {};
        variables.queue = [];
        variables.hostName = "";
        variables.queueLock = "";
        variables.excludeUrls = [];
        return this;
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
        
        logger.info( "CRAWLING" );
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

        return variables.pages;
    }

    /**
     * Validates a URL and checks if it matches the hostname
     * @url The URL to validate
     */
    private boolean function isValidUrl( required string url ) {
        try {
            var urlObj = createObject( "java", "java.net.URL" ).init( javaCast( "string", arguments.url ) );
            return urlObj.getHost( ) == variables.hostName && arguments.url.reMatch( settings.notAllowedPattern ).len( ) == 0;
        } catch ( any e ) {
            return false;
        }
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
            variables.pages.len( ) > settings.maxPages ||
            variables.pages.keyExists( arguments.url )
        ) {
            return;
        }

        logger.info( "Crawling #arguments.url# at depth #arguments.depth#" );
        var fetchResult = fetchUrl( arguments.url );
        if ( !isNull( fetchResult ) ) {
            
            var linkData = parser.getLinks( fetchResult.body, fetchResult );
            var pageUrl = parser.getCanonicalUrl( fetchResult.body );
            if ( !len( pageUrl ) ) {
                pageUrl = arguments.url;
            }

            variables.pages[ pageUrl ] = {
                fetched = true,
                lastModified = parser.getLastModified( fetchResult ),
                priority = settings.priority,
                depth = arguments.depth
            };
            
        }
    }

    /**
     * Fetches a URL using jSoup
     * @url The URL to fetch
     */
    private any function fetchUrl( required string url ) {
        try {
            var response = jSoup.connect( arguments.url )
                .timeout( settings.requestTimeout )
                .ignoreHttpErrors( true )
                .execute( );
            if ( response.statusCode( ) != 200 ) {
                logger.warn( "Failed to fetch #arguments.url#: Status #response.statusCode()#" );
                return;
            }
            return {
                url = arguments.url,
                body = response.parse( ),
                headers = response.headers( )
            };
        } catch ( any e ) {
            logger.error( "Error fetching #arguments.url#: #e.message#" );
            return;
        }
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
                !queueExists( arguments.url ) &&
                !variables.pages.keyExists( arguments.url ) &&
                !variables.excludeUrls.findNoCase( arguments.url )
            ) {
                logger.info( "ENQUEUE: #arguments.url#" );
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
            if ( variables.queue.len( ) ) {
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
    private boolean function queueExists( required string value ) {
        return variables.queue.findNoCase( arguments.value );
    }

}