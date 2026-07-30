component 
    hint="I am the sitemap service"
{

    property name="generator" inject="SitemapGenerator@sitemap-spider";
    property name="settings" inject="coldbox:moduleSettings:sitemap-spider";
    // The module registration struct, read for its version so the metadata
    // sidecar can record which module build wrote it.
    property name="moduleConfig" inject="coldbox:moduleConfig:sitemap-spider";
    property name="logger" inject="logbox:logger:{this}";
    // Used to resolve a fresh Crawler per create() call. The Crawler keeps its
    // whole crawl in variables scope, so it must not be shared across concurrent
    // crawls; see create().
    property name="wirebox" inject="Wirebox";


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
     * @excludePattern Optional regex for whole-section excludes, matched
     *   case-insensitively against the full URL (e.g. "/admin(?:/|\?|$)"). When
     *   non-empty it overrides the excludePattern module setting for this crawl
     *   only; empty falls back to the setting. A match skips the URL and reports
     *   it in `ignored` with reason "excluded". Separate from the exact-URL
     *   excludeUrls argument.
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
     * @progress Optional CrawlProgress the crawl updates as it runs, so a caller
     *   (e.g. SitemapJobRegistry) can poll live counts and request cancellation.
     *   When omitted, the crawl uses its own no-op progress and nothing changes.
     * @browserDsl Optional browser backend for this crawl only, e.g.
     *   "Playwright@sitemap-spider" for a site whose links need JavaScript.
     *   Empty uses the browserDsl module setting.
     * @includeImages Turn the image sitemap extension on or off for this crawl
     *   only. Omit the argument to use the includeImages module setting. The
     *   value reaches both the crawl (which collects the images) and the
     *   generator (which prints them), because a page struct carrying images
     *   the XML leaves out would be a waste, and the reverse cannot work.
     * @includeHreflang Same, for the hreflang alternates extension.
     * @includeVideos Same, for the video extension.
     * @writeMetadata When true, a JSON "sidecar" file is written after the
     *   sitemap, holding the stats struct, the options this crawl ran with, and
     *   the module version, so a host can show "last generated" stats later via
     *   readMetadata() without keeping job records. Defaults to the
     *   writeMetadata module setting (false). Requires filePath or metadataPath;
     *   with neither, nothing is written. A write failure throws
     *   sitemap-spider.MetadataSaveFailed (after the sitemap itself was saved).
     * @metadataPath Where to write the sidecar. Omit it to use the metadataPath
     *   module setting. Passing an explicit empty string puts the file next to
     *   the sitemap as "<filePath minus any .gz>.meta.json". That adjacent spot
     *   is usually the public webroot, so point the setting or argument outside
     *   the webroot to keep the sidecar private.
     * @metadataIncludeUrls When true, the sidecar also carries the full badUrls
     *   and ignored lists, not just their counts. Defaults to the
     *   metadataIncludeUrls module setting (false) because of the public-webroot
     *   note above.
     * @return A struct containing the crawled pages, sitemap XML, duration, and
     *   a pre-computed stats struct (see buildStats)
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
        boolean metadataIncludeUrls // Defaults to settings.metadataIncludeUrls below
    ) {
        // Default runAsync to the module setting when the caller did not pass it.
        param name="arguments.runAsync" default="#settings.runAsync#";

        // Same for the three sitemap extension flags. Resolved once here and
        // then handed to both the crawl and the generator below, so the two
        // always agree on which extensions this run is producing.
        param name="arguments.includeImages" default="#settings.includeImages#";
        param name="arguments.includeHreflang" default="#settings.includeHreflang#";
        param name="arguments.includeVideos" default="#settings.includeVideos#";

        // And the metadata sidecar options. param only supplies a default when
        // the key is absent, so an explicitly passed empty metadataPath remains
        // distinguishable and forces adjacent-file derivation.
        param name="arguments.writeMetadata" default="#settings.writeMetadata#";
        param name="arguments.metadataPath" default="#settings.metadataPath#";
        param name="arguments.metadataIncludeUrls" default="#settings.metadataIncludeUrls#";

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

        // Resolve a fresh Crawler for this call. The Crawler holds its entire
        // crawl in variables scope, so a shared instance would let two concurrent
        // create() calls overwrite each other's state. A fresh transient one gives
        // this crawl its own state and its own browser.
        var crawler = wirebox.getInstance( "Crawler@sitemap-spider" );

        // Pass progress only when the caller supplied it; otherwise the Crawler
        // builds its own no-op progress. Built as a struct so the optional
        // argument is never referenced when null.
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

        // Crawl the site and populate pages
        var result = crawler.crawl( argumentCollection = crawlArgs );

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
            includeImages  = arguments.includeImages,
            includeHreflang = arguments.includeHreflang,
            includeVideos  = arguments.includeVideos
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

        // One duration read shared by the stats struct and the duration key
        // below, so the two always agree.
        var durationMs = getTickCount() - start;

        // Pre-computed counts so a caller (a CMS stats screen, a job record)
        // never has to derive them from the raw arrays below.
        var stats = buildStats( result, setResult, durationMs );

        // Optionally write the metadata sidecar. It needs a target: the explicit
        // metadataPath, else a name derived from filePath. With neither, there
        // is nothing sensible to write, so the flag is a quiet no-op.
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
                // saveToFile creates missing parent directories; gzip stays off
                // so the sidecar is always plain JSON.
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
            // Report the path that was actually written (with ".gz" when gzip is
            // on); empty when nothing was saved.
            "filePath": len( arguments.filePath ) ? outputFilePath : arguments.filePath,
            "saved": saved,
            // Where the metadata sidecar went ("" when none was written).
            "metadataPath": metadataTarget,
            "metadataSaved": metadataSaved
        };
    }

    /**
     * readMetadata
     * Reads a metadata sidecar written by create( writeMetadata = true ) and
     * returns the parsed struct with exists=true added. Accepts either the
     * sidecar path itself or the sitemap filePath. A sitemap path resolves to
     * the metadataPath module setting when configured, otherwise the default
     * sidecar name is derived from it (".gz" stripped first). Returns
     * { "exists": false } when the file is missing or does not hold readable
     * JSON, so a caller's stats screen can treat "never generated" and
     * "unreadable" the same cheap way.
     */
    struct function readMetadata( required string path ) {
        // A path that is not already a sidecar is treated as the sitemap path.
        // The configured module default wins; otherwise derive the adjacent
        // filename. An explicit sidecar path is always read literally.
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
     * buildStats
     * Assembles the pre-computed counts returned as the result's stats key and
     * recorded in the metadata sidecar:
     *   generatedAt (ISO-8601 with offset), durationMs, urlCount (total <url>
     *   entries across all files), sitemapCount, type ("single"|"index"),
     *   badUrlCount, ignoredCount, redirectCount.
     * Keys are quoted so their casing survives JSON serialization on every
     * engine.
     */
    private struct function buildStats(
        required struct crawlResult,
        required struct setResult,
        required numeric durationMs
    ) {
        return {
            "generatedAt": iso8601( now() ),
            "durationMs": arguments.durationMs,
            // Every page becomes exactly one <url> entry — generateSet chunks
            // the same array when splitting — so one count serves both types.
            "urlCount": arguments.crawlResult.pages.len(),
            "sitemapCount": arguments.setResult.type == "index" ? arguments.setResult.sitemaps.len() : 1,
            "type": arguments.setResult.type,
            "badUrlCount": structCount( arguments.crawlResult.badUrls ),
            "ignoredCount": arguments.crawlResult.ignored.len(),
            "redirectCount": arguments.crawlResult.redirects.len()
        };
    }

    /**
     * buildMetadata
     * Assembles the sidecar struct: schemaVersion (bumped if the shape ever
     * changes so readers can branch), the module version, the stats struct, the
     * options the crawl effectively ran with, the written file path, and the
     * per-child-file counts for a split set. The full badUrls and ignored lists
     * are added only when includeUrls is true, because the sidecar's default
     * location is next to sitemap.xml in the public webroot, where anyone can
     * download it.
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
        // The first start URL, matching how the crawl itself picks its primary.
        var urlArray = isArray( arguments.createArgs.url )
            ? arguments.createArgs.url
            : [ arguments.createArgs.url ];

        var metadata = {
            "schemaVersion": 1,
            // In the dev harness the version is an unstamped build placeholder;
            // the guard keeps a missing key from throwing.
            "moduleVersion": moduleConfig.keyExists( "version" ) ? moduleConfig.version : "",
            "stats": arguments.stats,
            "options": {
                "url": urlArray[ 1 ],
                "includeImages": arguments.createArgs.includeImages,
                "includeHreflang": arguments.createArgs.includeHreflang,
                "includeVideos": arguments.createArgs.includeVideos,
                // What actually happened, not what was asked for: the crawl
                // degrades to sync when the browser is not parallel-safe.
                "runAsync": arguments.crawlResult.runAsync,
                "maxPages": settings.maxPages,
                "maxDepth": settings.maxDepth,
                "gzipOutput": arguments.gzip,
                "lastModFormat": settings.lastModFormat,
                // The effective values: a non-empty argument overrides the
                // module setting for the crawl, so record whichever applied.
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

        // For a split set, record each child file's name and URL count (not its
        // XML — the sidecar stays small).
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
     * Returns the sidecar path derived from a sitemap path: the sitemap path
     * with any trailing ".gz" removed, plus ".meta.json". So "sitemap.xml" and
     * "sitemap.xml.gz" both map to "sitemap.xml.meta.json", which is what lets
     * readMetadata accept either form.
     */
    private string function defaultMetadataPath( required string sitemapPath ) {
        var base = arguments.sitemapPath;
        if ( right( base, 3 ) == ".gz" ) {
            base = left( base, len( base ) - 3 );
        }
        return base & ".meta.json";
    }

    /**
     * iso8601
     * Formats a date as an ISO-8601 timestamp with the server's UTC offset
     * (e.g. "2026-07-29T14:03:22-07:00"), so generatedAt is written as a plain
     * string that round-trips through the JSON sidecar unchanged. Built from
     * CFML date-part functions via java.time, the same approach as
     * SitemapGenerator.formatLastMod's datetime path, because it behaves the
     * same on Adobe, Lucee, and BoxLang.
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
     * Return the value with a single trailing "/" so it can be concatenated with
     * a child filename to form an absolute URL.
     *
     * @value the URL prefix to normalize
     */
    private string function ensureTrailingSlash( required string value ) {
        return arguments.value.right( 1 ) == "/" ? arguments.value : arguments.value & "/";
    }

}
