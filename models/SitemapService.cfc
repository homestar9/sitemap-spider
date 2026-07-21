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
     * @return A struct containing the crawled pages, sitemap XML, and duration
     */
    struct function create(
        required any url, // String or array of strings
        array excludeUrls = [] // Array of URLs to exclude from crawling
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

        return {
            "pages": result.pages,
            "sitemap": sitemapXml,
            "duration": getTickCount() - start,
            "processedUrls": result.processedUrls,
            "badUrls": result.badUrls
        };
    }

}