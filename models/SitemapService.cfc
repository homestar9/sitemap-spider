component 
    hint="I am the sitemap service"
{

    property name="generator" inject="SitemapGenerator@sitemap-spider";
    property name="linkReportGenerator" inject="LinkReportGenerator@sitemap-spider";
    property name="settings" inject="coldbox:moduleSettings:sitemap-spider";
    // Supplies the module version written to metadata files.
    property name="moduleConfig" inject="coldbox:moduleConfig:sitemap-spider";
    property name="logger" inject="logbox:logger:{this}";
    // Resolves a new Crawler for each create() call.
    property name="wirebox" inject="Wirebox";


    /**
     * init
     *
     * Returns the initialized service.
     */
    function init() {
        return this;
    }
    
    /**
     * create
     *
     * Crawls one or more starting URLs and returns the generated sitemap.
     *
     * @url A URL or array of URLs to crawl. The first URL defines the host.
     * @seedUrls Extra starting URLs for pages that are not linked from `url`.
     *   Every seed must use the same host as the first URL.
     * @excludeUrls Exact URLs to skip.
     * @excludePattern Case-insensitive regex matched against each full URL.
     *   A non-empty value overrides the module setting for this crawl.
     * @filePath Full path for saved XML. A split sitemap writes its index here
     *   and writes child files beside it.
     * @publicBaseUrl URL prefix used for child locations in a sitemap index.
     *   Empty uses the first URL's directory.
     * @runAsync Enables parallel workers when the browser supports them.
     * @progress CrawlProgress object used for counts and cancellation.
     * @browserDsl Browser backend for this crawl. Empty uses the module setting.
     * @includeImages Enables image sitemap entries for this crawl.
     * @includeHreflang Enables hreflang entries for this crawl.
     * @includeVideos Enables video sitemap entries for this crawl.
     * @writeMetadata Saves a JSON metadata file after the sitemap.
     * @metadataPath Full metadata path. An explicit empty string derives the
     *   path from filePath.
     * @metadataIncludeUrls Includes the badUrls and ignored arrays in metadata.
     * @writeLinkReport Saves a JSON report of broken links, redirects, and
     *   skipped URLs after the sitemap.
     * @linkReportPath Full report path. An explicit empty string derives the path
     *   from filePath.
     * @return The crawl results, generated XML, file details, and statistics.
     */
    struct function create(
        required any url, // String or array of strings
        array seedUrls = [], // Extra start URLs for orphan pages not linked from url
        array excludeUrls = [], // Array of URLs to exclude from crawling
        string excludePattern = "", // Per-crawl section-exclude regex; overrides the module setting when non-empty
        string filePath = "", // Optional file path to save the sitemap XML to
        string publicBaseUrl = "", // Absolute URL prefix for <sitemapindex> entries
        boolean runAsync, // Defaults to settings.runAsync below
        any progress, // Optional CrawlProgress for live tracking + cancellation
        string browserDsl = "", // Per-crawl browser backend; empty uses the setting
        boolean includeImages, // Defaults to settings.includeImages below
        boolean includeHreflang, // Defaults to settings.includeHreflang below
        boolean includeVideos, // Defaults to settings.includeVideos below
        boolean writeMetadata, // Defaults to settings.writeMetadata below
        string metadataPath, // Omitted uses settings.metadataPath; explicit empty derives from filePath
        boolean metadataIncludeUrls, // Defaults to settings.metadataIncludeUrls below
        boolean writeLinkReport, // Defaults to settings.writeLinkReport below
        string linkReportPath // Omitted uses settings.linkReportPath; explicit empty derives from filePath
    ) {
        // Use the module setting when runAsync was not passed.
        param name="arguments.runAsync" default="#settings.runAsync#";

        // Use the same extension settings for collection and XML generation.
        param name="arguments.includeImages" default="#settings.includeImages#";
        param name="arguments.includeHreflang" default="#settings.includeHreflang#";
        param name="arguments.includeVideos" default="#settings.includeVideos#";

        // Keep an explicit empty path so metadata is saved beside the sitemap.
        param name="arguments.writeMetadata" default="#settings.writeMetadata#";
        param name="arguments.metadataPath" default="#settings.metadataPath#";
        param name="arguments.metadataIncludeUrls" default="#settings.metadataIncludeUrls#";

        // Keep an explicit empty path so the report is saved beside the sitemap.
        param name="arguments.writeLinkReport" default="#settings.writeLinkReport#";
        param name="arguments.linkReportPath" default="#settings.linkReportPath#";

        var start = getTickCount();

        // Convert the primary URL input to an array.
        var urlArray = isArray( arguments.url ) ? arguments.url : [ arguments.url ];

        // Add the extra seeds without changing the caller's URL array.
        // urlArray[1] remains the primary URL that defines the host.
        var crawlSeeds = [];
        crawlSeeds.append( urlArray, true );
        crawlSeeds.append( arguments.seedUrls, true );

        // Crawler stores crawl state in variables scope. Each call must use a
        // fresh instance so concurrent crawls cannot overwrite each other.
        var crawler = wirebox.getInstance( "Crawler@sitemap-spider" );

        // Pass progress only when the caller supplied it. Crawler creates a
        // default CrawlProgress object when this key is absent.
        var crawlArgs = {
            urls = crawlSeeds,
            excludeUrls = arguments.excludeUrls,
            excludePattern = arguments.excludePattern,
            runAsync = arguments.runAsync,
            browserDsl = arguments.browserDsl,
            includeImages = arguments.includeImages,
            includeHreflang = arguments.includeHreflang,
            includeVideos = arguments.includeVideos
        };
        if ( !isNull( arguments.progress ) ) {
            crawlArgs.progress = arguments.progress;
        }

        // Crawl the site and collect its pages.
        var result = crawler.crawl( argumentCollection = crawlArgs );

        // Build the public URL prefix used by split sitemap files.
        var baseUrl = len( arguments.publicBaseUrl )
            ? ensureTrailingSlash( arguments.publicBaseUrl )
            : ensureTrailingSlash( urlArray[ 1 ].reReplace( "[^/]*$", "" ) );

        // Child sitemap names are based on the primary filename.
        var primaryFilename = len( arguments.filePath ) ? getFileFromPath( arguments.filePath ) : "sitemap.xml";

        // Gzip applies only to files saved to disk.
        var gzip = settings.gzipOutput && len( arguments.filePath );

        // Generate one URL set or a sitemap index with child URL sets.
        var setResult = generator.generateSet(
            pages          = result.pages,
            publicBaseUrl  = baseUrl,
            primaryFilename = primaryFilename,
            maxUrls        = settings.maxUrlsPerSitemap,
            maxBytes       = settings.maxSitemapBytes,
            gzip           = gzip,
            lastModFormat  = settings.lastModFormat,
            includeImages  = arguments.includeImages,
            includeHreflang = arguments.includeHreflang,
            includeVideos  = arguments.includeVideos
        );

        // Add .gz once so filePath reports the file that was written.
        var outputFilePath = ( gzip && right( arguments.filePath, 3 ) != ".gz" )
            ? arguments.filePath & ".gz"
            : arguments.filePath;

        // Save the main file and then each child file. Throw SaveFailed when any
        // write fails so the caller does not treat an incomplete write as saved.
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

        // Reuse one duration value in both return locations.
        var durationMs = getTickCount() - start;

        // Build counts for callers that do not need the full arrays.
        var stats = buildStats( result, setResult, durationMs );

        // Save metadata when writeMetadata is enabled and a path can be found.
        var metadataTarget = "";
        var metadataSaved  = false;
        if ( arguments.writeMetadata && ( len( arguments.filePath ) || len( arguments.metadataPath ) ) ) {
            metadataTarget = len( arguments.metadataPath )
                ? arguments.metadataPath
                : defaultMetadataPath( arguments.filePath );
            var metadata = buildMetadata(
                stats          = stats,
                crawlResult    = result,
                setResult      = setResult,
                createArgs     = arguments,
                outputFilePath = len( arguments.filePath ) ? outputFilePath : "",
                gzip           = gzip,
                includeUrls    = arguments.metadataIncludeUrls
            );
            try {
                // Metadata is always plain JSON, even when the sitemap is gzipped.
                generator.saveToFile( serializeJSON( metadata ), metadataTarget, false );
                metadataSaved = true;
            } catch ( any e ) {
                logger.error( "Failed to save sitemap metadata to #metadataTarget#: #e.message#", e );
                throw(
                    type = "sitemap-spider.MetadataSaveFailed",
                    message = "Could not save sitemap metadata to '#metadataTarget#'",
                    detail = e.message
                );
            }
        }

        // Save the link report when enabled and a path can be found.
        var linkReportTarget = "";
        var linkReportSaved  = false;
        if ( arguments.writeLinkReport && ( len( arguments.filePath ) || len( arguments.linkReportPath ) ) ) {
            linkReportTarget = len( arguments.linkReportPath )
                ? arguments.linkReportPath
                : defaultLinkReportPath( arguments.filePath );
            var linkReport = linkReportGenerator.generate(
                crawlResult   = result,
                site          = urlArray[ 1 ],
                // Development builds can have no stamped version.
                moduleVersion = moduleConfig.keyExists( "version" ) ? moduleConfig.version : "",
                generatedAt   = stats.generatedAt
            );
            try {
                // Keep the report as plain JSON when the sitemap uses gzip.
                generator.saveToFile( serializeJSON( linkReport ), linkReportTarget, false );
                linkReportSaved = true;
            } catch ( any e ) {
                logger.error( "Failed to save link report to #linkReportTarget#: #e.message#", e );
                throw(
                    type = "sitemap-spider.LinkReportSaveFailed",
                    message = "Could not save link report to '#linkReportTarget#'",
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
            "duration": durationMs,
            "stats": stats,
            "processedUrls": result.processedUrls,
            "badUrls": result.badUrls,
            "ignored": result.ignored,
            "redirects": result.redirects,
            "runAsync": result.runAsync,
            // Return the actual path, including .gz when compression was used.
            "filePath": len( arguments.filePath ) ? outputFilePath : arguments.filePath,
            "saved": saved,
            // Return an empty path when no metadata file was written.
            "metadataPath": metadataTarget,
            "metadataSaved": metadataSaved,
            // Return an empty path when no link report was written.
            "linkReportPath": linkReportTarget,
            "linkReportSaved": linkReportSaved
        };
    }

    /**
     * readMetadata
     *
     * Reads a metadata file and adds exists=true to the returned struct.
     * A sitemap path resolves through the metadataPath setting or its derived
     * sidecar name. Missing or invalid JSON returns { "exists": false }.
     */
    struct function readMetadata( required string path ) {
        // Treat any path without .meta.json as a sitemap path.
        var target = arguments.path;
        if ( right( target, 10 ) != ".meta.json" ) {
            target = len( settings.metadataPath )
                ? settings.metadataPath
                : defaultMetadataPath( target );
        }
        if ( !fileExists( target ) ) {
            return { "exists": false };
        }
        var raw = fileRead( target );
        if ( !isJSON( raw ) ) {
            logger.warn( "Sitemap metadata at #target# is not readable JSON" );
            return { "exists": false };
        }
        var metadata = deserializeJSON( raw );
        metadata[ "exists" ] = true;
        return metadata;
    }

    /**
     * readLinkReport
     *
     * Reads a link report and adds exists=true. A sitemap path uses the configured
     * or derived report path. Missing or invalid JSON returns { "exists": false }.
     */
    struct function readLinkReport( required string path ) {
        // Treat any path without .links.json as a sitemap path.
        var target = arguments.path;
        if ( right( target, 11 ) != ".links.json" ) {
            target = len( settings.linkReportPath )
                ? settings.linkReportPath
                : defaultLinkReportPath( target );
        }
        if ( !fileExists( target ) ) {
            return { "exists": false };
        }
        var raw = fileRead( target );
        if ( !isJSON( raw ) ) {
            logger.warn( "Link report at #target# is not readable JSON" );
            return { "exists": false };
        }
        var report = deserializeJSON( raw );
        report[ "exists" ] = true;
        return report;
    }

    /**
     * buildStats
     *
     * Returns the counts stored in the result and metadata file. Quoted keys
     * preserve their case during JSON serialization on every supported engine.
     */
    private struct function buildStats(
        required struct crawlResult,
        required struct setResult,
        required numeric durationMs
    ) {
        return {
            "generatedAt": iso8601( now() ),
            "durationMs": arguments.durationMs,
            // Each page becomes one <url>, including when files are split.
            "urlCount": arguments.crawlResult.pages.len(),
            "sitemapCount": arguments.setResult.type == "index" ? arguments.setResult.sitemaps.len() : 1,
            "type": arguments.setResult.type,
            "badUrlCount": structCount( arguments.crawlResult.badUrls ),
            "ignoredCount": arguments.crawlResult.ignored.len(),
            "redirectCount": arguments.crawlResult.redirects.len(),
            // Assets are files the crawler checked but never added to the sitemap.
            "assetsCheckedCount": arguments.crawlResult.assetsChecked,
            "assetsBrokenCount": countBadAssets( arguments.crawlResult.badUrls )
        };
    }

    /**
     * countBadAssets
     *
     * Returns how many failed URLs were assets rather than pages.
     *
     * @badUrls The crawl's badUrls struct.
     */
    private numeric function countBadAssets( required struct badUrls ) {
        var count = 0;
        for ( var badUrl in arguments.badUrls ) {
            var entry = arguments.badUrls[ badUrl ];
            if ( entry.keyExists( "kind" ) && entry.kind == "asset" ) {
                count++;
            }
        }
        return count;
    }

    /**
     * buildMetadata
     *
     * Builds the metadata file contents. badUrls and ignored are included only
     * when includeUrls is true because the default path can be publicly readable.
     */
    private struct function buildMetadata(
        required struct stats,
        required struct crawlResult,
        required struct setResult,
        required struct createArgs,
        required string outputFilePath,
        required boolean gzip,
        required boolean includeUrls
    ) {
        // Store the same primary URL used by the crawler.
        var urlArray = isArray( arguments.createArgs.url )
            ? arguments.createArgs.url
            : [ arguments.createArgs.url ];

        var metadata = {
            "schemaVersion": 1,
            // A development build may not have a stamped version.
            "moduleVersion": moduleConfig.keyExists( "version" ) ? moduleConfig.version : "",
            "stats": arguments.stats,
            "options": {
                "url": urlArray[ 1 ],
                "includeImages": arguments.createArgs.includeImages,
                "includeHreflang": arguments.createArgs.includeHreflang,
                "includeVideos": arguments.createArgs.includeVideos,
                // Record the mode the crawler actually used.
                "runAsync": arguments.crawlResult.runAsync,
                "maxPages": settings.maxPages,
                "maxDepth": settings.maxDepth,
                "gzipOutput": arguments.gzip,
                "lastModFormat": settings.lastModFormat,
                // Record the per-crawl override or its module default.
                "excludePattern": len( arguments.createArgs.excludePattern )
                    ? arguments.createArgs.excludePattern
                    : settings.excludePattern,
                "browserDsl": len( arguments.createArgs.browserDsl )
                    ? arguments.createArgs.browserDsl
                    : settings.browserDsl,
                "userAgent": settings.userAgent
            },
            "filePath": arguments.outputFilePath,
            "sitemaps": []
        };

        // Store child names and counts without copying their XML.
        if ( arguments.setResult.type == "index" ) {
            for ( var child in arguments.setResult.sitemaps ) {
                metadata.sitemaps.append( {
                    "filename": child.filename,
                    "urlCount": child.urlCount
                } );
            }
        }

        if ( arguments.includeUrls ) {
            metadata[ "badUrls" ] = arguments.crawlResult.badUrls;
            metadata[ "ignored" ] = arguments.crawlResult.ignored;
        }

        return metadata;
    }

    /**
     * defaultMetadataPath
     *
     * Removes a trailing .gz and appends .meta.json to a sitemap path.
     */
    private string function defaultMetadataPath( required string sitemapPath ) {
        return sidecarPath( arguments.sitemapPath, ".meta.json" );
    }

    /**
     * defaultLinkReportPath
     *
     * Removes a trailing .gz and appends .links.json to a sitemap path.
     */
    private string function defaultLinkReportPath( required string sitemapPath ) {
        return sidecarPath( arguments.sitemapPath, ".links.json" );
    }

    /**
     * sidecarPath
     *
     * Builds a sidecar path. Removes .gz first so the suffix follows .xml.
     *
     * @sitemapPath Path of the sitemap the sidecar belongs to.
     * @suffix Suffix for the sidecar, including its leading dot.
     */
    private string function sidecarPath( required string sitemapPath, required string suffix ) {
        var base = arguments.sitemapPath;
        if ( right( base, 3 ) == ".gz" ) {
            base = left( base, len( base ) - 3 );
        }
        return base & arguments.suffix;
    }

    /**
     * iso8601
     *
     * Formats a date as an ISO-8601 timestamp with the server's UTC offset.
     * java.time produces the same result on Adobe, Lucee, and BoxLang.
     */
    private string function iso8601( required date value ) {
        var ldt = createObject( "java", "java.time.LocalDateTime" ).of(
            javaCast( "int", year( arguments.value ) ),
            javaCast( "int", month( arguments.value ) ),
            javaCast( "int", day( arguments.value ) ),
            javaCast( "int", hour( arguments.value ) ),
            javaCast( "int", minute( arguments.value ) ),
            javaCast( "int", second( arguments.value ) )
        );
        var zone = createObject( "java", "java.time.ZoneId" ).systemDefault();
        var fmt  = createObject( "java", "java.time.format.DateTimeFormatter" )
            .ofPattern( javaCast( "string", "yyyy-MM-dd'T'HH:mm:ssxxx" ) );
        return ldt.atZone( zone ).toOffsetDateTime().format( fmt );
    }

    /**
     * ensureTrailingSlash
     *
     * Adds a trailing slash when the value does not already have one.
     *
     * @value the URL prefix to normalize
     */
    private string function ensureTrailingSlash( required string value ) {
        return arguments.value.right( 1 ) == "/" ? arguments.value : arguments.value & "/";
    }

}
