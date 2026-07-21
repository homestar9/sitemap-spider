component 
    hint="I am the sitemap service"
{

    property name="crawler" inject="Crawler@sitemap-spider";
    property name="generator" inject="SitemapGenerator@sitemap-spider";
    property name="settings" inject="coldbox:moduleSettings:sitemap-spider";
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
     * @excludeUrls Array of URLs to exclude from crawling
     * @filePath Optional full path to save the sitemap XML to. When set, the XML
     *   is written there (creating the directory if needed) and the return struct
     *   reports saved=true. A write failure throws sitemap-spider.SaveFailed.
     * @return A struct containing the crawled pages, sitemap XML, and duration
     */
    struct function create(
        required any url, // String or array of strings
        array excludeUrls = [], // Array of URLs to exclude from crawling
        string filePath = "" // Optional file path to save the sitemap XML to
    ) {
        var start = getTickCount();

        // Normalize url to an array
        var urlArray = isArray( arguments.url ) ? arguments.url : [ arguments.url ];

        // Crawl the site and populate pages
        var result = crawler.crawl(
            urls = urlArray,
            excludeUrls = arguments.excludeUrls
        );

        // Generate sitemap XML
        var sitemapXml = generator.generate( result.pages );

        // Optionally save the XML to disk. A failure here is surfaced as a typed
        // error rather than swallowed, so the caller knows the file was not written.
        var saved = false;
        if ( len( arguments.filePath ) ) {
            try {
                generator.saveToFile( sitemapXml, arguments.filePath );
                saved = true;
            } catch ( any e ) {
                logger.error( "Failed to save sitemap to #arguments.filePath#: #e.message#", e );
                throw(
                    type = "sitemap-spider.SaveFailed",
                    message = "Could not save sitemap to '#arguments.filePath#'",
                    detail = e.message
                );
            }
        }

        return {
            "pages": result.pages,
            "sitemap": sitemapXml,
            "duration": getTickCount() - start,
            "processedUrls": result.processedUrls,
            "badUrls": result.badUrls,
            "disallowedUrls": result.disallowedUrls,
            "filePath": arguments.filePath,
            "saved": saved
        };
    }

}