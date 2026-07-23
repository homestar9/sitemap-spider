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
     * @seedUrls Optional extra start URLs for pages not linked from `url` (orphan
     *   pages). They are added to the crawl frontier alongside `url`. All seeds
     *   must share the host of `url`: the host, robots.txt base, and split-file
     *   base URL are all taken from the first `url`, not from seedUrls.
     * @excludeUrls Array of URLs to exclude from crawling
     * @filePath Optional full path to save the sitemap XML to. When set, the XML
     *   is written there (creating the directory if needed) and the return struct
     *   reports saved=true. A write failure throws sitemap-spider.SaveFailed. When
     *   the crawl exceeds the per-file limits, this becomes the <sitemapindex>
     *   file and child sitemaps are written beside it (its basename + "-N").
     * @publicBaseUrl Absolute URL prefix the child sitemaps are served from, used
     *   for the <sitemapindex> <loc> entries (only relevant when splitting). When
     *   empty, it is derived from the first start URL's directory.
     * @runAsync When true, crawl URLs on several worker threads. Defaults to the
     *   module's runAsync setting. The crawler honors it when the browser backend
     *   is parallel-safe; otherwise the crawl runs single-threaded. A robots
     *   Crawl-delay no longer forces sync — the delay is applied as a shared
     *   per-fetch spacing across the workers. The returned struct's runAsync key
     *   reports whether the crawl actually ran in parallel.
     * @return A struct containing the crawled pages, sitemap XML, and duration
     */
    struct function create(
        required any url, // String or array of strings
        array seedUrls = [], // Extra start URLs for orphan pages not linked from url
        array excludeUrls = [], // Array of URLs to exclude from crawling
        string filePath = "", // Optional file path to save the sitemap XML to
        string publicBaseUrl = "", // Absolute URL prefix for <sitemapindex> entries
        boolean runAsync // Defaults to settings.runAsync below
    ) {
        // Default runAsync to the module setting when the caller did not pass it.
        param name="arguments.runAsync" default="#settings.runAsync#";

        var start = getTickCount();

        // Normalize url to an array
        var urlArray = isArray( arguments.url ) ? arguments.url : [ arguments.url ];

        // The crawl frontier is seeded from url plus any extra seedUrls. urlArray[1]
        // stays the primary (host, robots base, split-file base URL); seedUrls only
        // add more entry points so orphan pages can be reached. Built as a fresh
        // array so a caller who passed url as an array is not mutated.
        var crawlSeeds = [];
        crawlSeeds.append( urlArray, true );
        crawlSeeds.append( arguments.seedUrls, true );

        // Crawl the site and populate pages
        var result = crawler.crawl(
            urls = crawlSeeds,
            excludeUrls = arguments.excludeUrls,
            runAsync = arguments.runAsync
        );

        // The absolute URL prefix the child sitemaps are served from. Prefer the
        // caller's publicBaseUrl; otherwise use the first start URL's directory
        // (everything up to and including its last "/"), which is where the
        // sitemap files are assumed to live.
        var baseUrl = len( arguments.publicBaseUrl )
            ? ensureTrailingSlash( arguments.publicBaseUrl )
            : ensureTrailingSlash( urlArray[ 1 ].reReplace( "[^/]*$", "" ) );

        // The filename the primary file (index or single) is written as. Child
        // sitemaps derive their names from it. Defaults to "sitemap.xml" when no
        // filePath was given (still used to name the <sitemapindex> children).
        var primaryFilename = len( arguments.filePath ) ? getFileFromPath( arguments.filePath ) : "sitemap.xml";

        // Gzip only applies when we are actually writing files. When on, the
        // generated child filenames and index <loc> entries carry ".gz", and the
        // files below are written compressed.
        var gzip = settings.gzipOutput && len( arguments.filePath );

        // Generate the sitemap set. Below the per-file limits this is a single
        // <urlset>; above them it is a <sitemapindex> plus child <urlset> files.
        var setResult = generator.generateSet(
            pages          = result.pages,
            publicBaseUrl  = baseUrl,
            primaryFilename = primaryFilename,
            maxUrls        = settings.maxUrlsPerSitemap,
            maxBytes       = settings.maxSitemapBytes,
            gzip           = gzip,
            lastModFormat  = settings.lastModFormat,
            includeImages  = settings.includeImages
        );

        // The path the primary file is actually written to. With gzip on, ".gz"
        // is appended (once — a filePath that already ends in ".gz" is left as
        // is), so the returned filePath below points at the file that exists on
        // disk.
        var outputFilePath = ( gzip && right( arguments.filePath, 3 ) != ".gz" )
            ? arguments.filePath & ".gz"
            : arguments.filePath;

        // Optionally save to disk. A failure here is surfaced as a typed error
        // rather than swallowed, so the caller knows the file was not written.
        // For a split set the index is written to outputFilePath and each child is
        // written beside it under its derived filename (already carrying ".gz"
        // when gzip is on).
        var saved    = false;
        var sitemaps = setResult.sitemaps;
        if ( len( arguments.filePath ) ) {
            try {
                generator.saveToFile( setResult.xml, outputFilePath, gzip );
                if ( setResult.type == "index" ) {
                    var dir = getDirectoryFromPath( arguments.filePath );
                    for ( var child in sitemaps ) {
                        child.filePath = dir & child.filename;
                        generator.saveToFile( child.xml, child.filePath, gzip );
                    }
                }
                saved = true;
            } catch ( any e ) {
                logger.error( "Failed to save sitemap to #outputFilePath#: #e.message#", e );
                throw(
                    type = "sitemap-spider.SaveFailed",
                    message = "Could not save sitemap to '#outputFilePath#'",
                    detail = e.message
                );
            }
        }

        return {
            "pages": result.pages,
            "sitemap": setResult.xml,
            "type": setResult.type,
            "sitemaps": sitemaps,
            "sitemapCount": setResult.type == "index" ? sitemaps.len() : 1,
            "duration": getTickCount() - start,
            "processedUrls": result.processedUrls,
            "badUrls": result.badUrls,
            "disallowedUrls": result.disallowedUrls,
            "ignored": result.ignored,
            "redirects": result.redirects,
            "runAsync": result.runAsync,
            // Report the path that was actually written (with ".gz" when gzip is
            // on); empty when nothing was saved.
            "filePath": len( arguments.filePath ) ? outputFilePath : arguments.filePath,
            "saved": saved
        };
    }

    /**
     * ensureTrailingSlash
     * Return the value with a single trailing "/" so it can be concatenated with
     * a child filename to form an absolute URL.
     *
     * @value the URL prefix to normalize
     */
    private string function ensureTrailingSlash( required string value ) {
        return arguments.value.right( 1 ) == "/" ? arguments.value : arguments.value & "/";
    }

}