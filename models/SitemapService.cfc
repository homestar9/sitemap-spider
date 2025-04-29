component 
    hint="I am the sitemap service"
{

    property name="crawler" inject="Crawler@sitemap-spider";
    property name="generator" inject="SitemapGenerator@sitemap-spider";
    property name="settings" inject="coldbox:moduleSettings:sitemap-spider";
    
    property name="jSoup" inject="javaloader:org.jsoup.Jsoup";
    property name="asyncManager" inject="asyncManager@coldbox";
    property name="logger" inject="logbox:logger:{this}";


    /**
     * Initializes the service
     */
    function init() {
        return this;
    }
    
    /**
     * create
     * Creates a sitemap starting from one or more URLs
     * 
     * @url A single URL (string) or array of URLs to start crawling
     * @runAsync Whether to run the crawler asynchronously
     * @return A struct containing the crawled pages, sitemap XML, and duration
     */
    struct function create(
        required any url, // String or array of strings
        array excludeUrls = [], // Array of URLs to exclude from crawling
        boolean runAsync = settings.runAsync
    ) {
        var start = getTickCount();
        variables.runAsync = runAsync;

        // Normalize url to an array
        var urlArray = isArray( arguments.url ) ? arguments.url : [ arguments.url ];

        // Crawl the site and populate pages
        var pages = crawler.crawl(
            urls = urlArray,
            excludeUrls = arguments.excludeUrls, 
            runAsync = arguments.runAsync 
        );

        // Generate sitemap XML
        var sitemapXml = generator.generate( pages );

        return {
            "pages": pages,
            "sitemap": sitemapXml,
            "duration": getTickCount() - start
        };
    }

    /**
     * crawl
     * Recursive method to crawl a URL and any links on that URL
     *
     * @url url to check
     * @depth the depth of the crawl recursion
     * @priority the priority of the web page
     */
    private void function crawl( 
        required string url, 
        required numeric depth,
        numeric priority=1
    ) {
        
        logger.info( "Crawling #arguments.url# at depth #arguments.depth#" );
        
        // if this page has already been crawled, or if we have exceeded our max depth, ignore it
        if ( 
            arguments.depth > variables.maxDepth ||
            variables.pages.len() > variables.maxPages || 
            variables.pages.keyExists( arguments.url ) 
        ) {
            return;
        }

        // Get the page from a url. We will get back an object or null
        var fetchResult = fetchUrl( arguments.url );

        // if the result is null, we can't parse it.
        if ( isNull( fetchResult ) ) {
            return;
        }

        // add this url to the list of crawled pages
        variables.pages[ arguments.url ] = {
            "fetched": true,
            "lastModified": getLastModified( fetchResult ),
            "priority": arguments.priority,
            "depth": arguments.depth
        };

        // Now get links and append to the crawl queue;
        getLinks( fetchResult.body ).each( function( url, index ) {
            enqueue( arguments.url, depth + 1 );
        } );

    }


    /**
     * getLinks
     * Returns an array of links found in a page object
     * We also clean the link of unexpected characters and only add links that should be allowed
     *
     * @page 
     */
    function getLinks( required page ) {
        var links = []; // will hold an array of urls
        
        page.select( 'a[href]' ).each( function( link, index ) {
            var linkUrl = cleanUrl( arguments.link.attr( "href" ) );
            logger.info( "Link Found: #linkUrl# (#(!links.find( linkUrl ) && isUrlAllowed( linkUrl ) ? 'Added' : 'Skipped' )#)" );
            // if the url is allowed and isn't already in the list, add it
            if ( 
                !links.find( linkUrl ) &&
                isUrlAllowed( linkUrl ) 
            ) {
                links.append( linkUrl );
            }
        } );

        return links;
    }

    
    /**
     * fetchUrl
     * Retrieves a page from a specific url
     *
     * @url the url to fetch
     */
    private any function fetchUrl( required string url ) {
        try {
            var response = jSoup.connect( arguments.url ).ignoreHttpErrors(true).execute();
            
            // throw exception if non successful status code
            if ( response.statusCode() != "200" ) {
                logger.error( "Failed to fetch #arguments.url#: Status #response.statusCode()#" );
                return;
            }
            var headers = response.headers(); // java.util.LinkedHashMap which can be used like a struct
            var body = response.parse();
            return {
                "url": arguments.url,
                "body" : body,
                "headers": headers
            };
        } catch ( any e ) {
            logger.error( "Failed to fetch #arguments.url#: Status #e.message#" );
            return;
        }
    }


    /**
     * Helper function to clean the URL
     * Removes spaces, pound signs, and makes all slashes forward slashes
     *
     * @url the url to clean
     */
    private function cleanUrl( required string url ) {
        return arguments.url.replace( " ", "" ).replace( "##", "" ).replace( "%20", "" ).replace( "\", "/" );
    }

    /**
     * isUrlAllowed
     * 
     * @link url to check
     */
    private boolean function isUrlAllowed( required string url ) {
        var allowed = true;

        if ( 
            !len( arguments.url ) || 
            !startsWith( arguments.url, variables.hostName )
        ) {
            return false;
        }

        for ( var ext in variables.notAllowed ) {
            if ( findNoCase( ext, arguments.url ) ) {
                allowed = false;
                break;
            }
        }
        return allowed;
    }

    /**
     * StartsWith
     * returns trus if the passed word starts with the substring
     *
     * @word 
     * @substring 
     */
    private function startsWith( word, substring ) {
        return left( word, len( substring ) ) == substring;
    }

    /**
     * Undocumented function
     *
     * @url 
     * @depth 
     */
    private function enqueue( required string url, required numeric depth ) {
        lock
            timeout = 30
            type = "exclusive"
            name = variables.queueLock
        {
            if ( !queueExists( arguments.url ) ) {
                logger.info( 'ENQUEUE: #arguments.url#' );
                variables.queue.append( { 
                    "url": arguments.url, 
                    "depth": arguments.depth 
                } );
            }
        }
    }

    /**
     * dequeue
     *
     * @url 
     * @depth 
     */
    private function dequeue() {
        lock
            timeout = 30
            type = "exclusive"
            name = variables.queueLock
        {
            if ( variables.queue.len() ) {
                var current = variables.queue[ 1 ]; // do I need to dupicate first?
                variables.queue.deleteAt( 1 );
            }
        }
        return local.keyExists( "current" ) ? current : javaCast( "null", 0 );
    }

    /**
     * queueExists
     * Performs a case sensitive check for the existence of a url in the queue
     *
     * @value 
     */
    private boolean function queueExists( required string value ) {
        return variables.queue.find( function( item ) {
            return ( compare( item.url, value ) == 0 );
        } );
    }

    /**
     * getLastModified
     * 
     * @page the page object to parse
     */
    private function getLastModified( required fetchResult ) {
        // check header
        if ( len( fetchResult.headers.keyExists( "Last-Modified" ) ) ) {
            return fetchResult.headers.keyExists( "Last-Modified" );
        }
        // todo: check custom selector

        return ""; // no date
    }

    private function runQueueItem() {
        var current = dequeue(); // pull the first element
            
        if ( !isNull( current ) ) {
            crawl( 
                url =current.url,
                depth = current.depth
            );
        }
    }

}