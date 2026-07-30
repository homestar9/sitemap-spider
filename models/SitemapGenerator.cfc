component {

    // Shared XML tags keep single and split sitemap files consistent.
    variables.xmlHeader   = '<?xml version="1.0" encoding="UTF-8"?>';
    variables.urlsetOpen  = '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">';
    variables.urlsetClose = '</urlset>';
    variables.indexOpen   = '<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">';
    variables.indexClose  = '</sitemapindex>';

    /**
     * init
     *
     * Returns the initialized generator.
     */
    function init() {
        return this;
    }

    /**
     * generate
     *
     * Returns one <urlset> XML document. Use generateSet() when the sitemap can
     * exceed the sitemaps.org file limits.
     *
     * @pages Page structs containing URL, date, priority, and extension data.
     * @lastModFormat "date" or "datetime".
     * @includeImages Adds image entries and their namespace.
     * @includeHreflang Adds hreflang entries and their namespace.
     * @includeVideos Adds video entries and their namespace.
     */
    function generate(
        required array pages,
        string lastModFormat = "date",
        boolean includeImages = false,
        boolean includeHreflang = false,
        boolean includeVideos = false
    ) {
        var xml = variables.xmlHeader
            & urlsetOpenTag( arguments.includeImages, arguments.includeHreflang, arguments.includeVideos );
        for ( var data in arguments.pages ) {
            xml &= buildUrlEntry( data, lastModFormat, includeImages, includeHreflang, includeVideos );
        }
        xml &= variables.urlsetClose;
        return xml;
    }

    /**
     * generateSet
     *
     * Returns one sitemap or splits pages into numbered child sitemaps and an
     * index when either file limit is reached.
     *
     * @pages Page structs to write.
     * @publicBaseUrl Absolute URL prefix for child sitemap locations.
     * @primaryFilename Filename used to derive numbered child names.
     * @maxUrls Maximum URLs in one child file.
     * @maxBytes Maximum uncompressed bytes in one child file.
     * @gzip Adds .gz to child names and index locations. XML remains plain text.
     * @lastModFormat "date" or "datetime".
     * @includeImages Adds image entries and their namespace.
     * @includeHreflang Adds hreflang entries and their namespace.
     * @includeVideos Adds video entries and their namespace.
     */
    function generateSet(
        required array pages,
        string publicBaseUrl = "",
        string primaryFilename = "sitemap.xml",
        numeric maxUrls = 50000,
        numeric maxBytes = 52428800,
        boolean gzip = false,
        string lastModFormat = "date",
        boolean includeImages = false,
        boolean includeHreflang = false,
        boolean includeVideos = false
    ) {
        // Use the same opening tag for every child and for byte counting.
        var urlsetOpen = urlsetOpenTag( arguments.includeImages, arguments.includeHreflang, arguments.includeVideos );

        // Include the XML tags in each child's byte limit.
        var envelopeBytes = byteLength( variables.xmlHeader & urlsetOpen & variables.urlsetClose );

        // Each chunk tracks its XML, URL count, bytes, and newest last-modified date.
        var chunks  = [];
        var current = ""; // Becomes a chunk when the first entry is added.

        for ( var data in arguments.pages ) {
            var entry = buildUrlEntry(
                data,
                arguments.lastModFormat,
                arguments.includeImages,
                arguments.includeHreflang,
                arguments.includeVideos
            );
            var entryBytes = byteLength( entry );

            // Start a child before adding an entry that would exceed a limit.
            // One oversized entry still receives its own child file.
            var needNewChunk = isSimpleValue( current )
                || current.count >= arguments.maxUrls
                || ( current.bytes + entryBytes > arguments.maxBytes );

            if ( needNewChunk ) {
                current = {
                    builder : createObject( "java", "java.lang.StringBuilder" ).init(),
                    count   : 0,
                    bytes   : envelopeBytes,
                    lastMod : ""
                };
                chunks.append( current );
            }

            current.builder.append( entry );
            current.count += 1;
            current.bytes += entryBytes;
            if ( isDate( data.lastModified )
                && ( !isDate( current.lastMod ) || data.lastModified > current.lastMod ) ) {
                current.lastMod = data.lastModified;
            }
        }

        // Return one URL set when no split is needed.
        if ( chunks.len() <= 1 ) {
            var body = chunks.len() ? chunks[ 1 ].builder.toString() : "";
            return {
                type     : "single",
                xml      : variables.xmlHeader & urlsetOpen & body & variables.urlsetClose,
                sitemaps : []
            };
        }

        // Build each child URL set and the sitemap index.
        var sitemaps  = [];
        var indexBody = "";
        for ( var i = 1; i <= chunks.len(); i++ ) {
            // Add .gz after creating the numbered XML filename.
            var filename  = childFilename( arguments.primaryFilename, i );
            if ( arguments.gzip ) {
                filename &= ".gz";
            }
            var childXml  = variables.xmlHeader & urlsetOpen & chunks[ i ].builder.toString() & variables.urlsetClose;
            var hasDate   = isDate( chunks[ i ].lastMod );
            var lastModStr = hasDate ? formatLastMod( chunks[ i ].lastMod, arguments.lastModFormat ) : "";

            indexBody &= '<sitemap>';
            indexBody &= '<loc>#xmlFormat( arguments.publicBaseUrl & filename )#</loc>';
            if ( hasDate ) {
                indexBody &= '<lastmod>#lastModStr#</lastmod>';
            }
            indexBody &= '</sitemap>';

            sitemaps.append( {
                filename : filename,
                xml      : childXml,
                lastmod  : lastModStr,
                urlCount : chunks[ i ].count
            } );
        }

        return {
            type     : "index",
            xml      : variables.xmlHeader & variables.indexOpen & indexBody & variables.indexClose,
            sitemaps : sitemaps
        };
    }

    /**
     * buildUrlEntry
     *
     * Builds one <url> entry for both single and split sitemaps.
     *
     * @data Page struct with core and optional extension data.
     * @lastModFormat "date" or "datetime".
     * @includeImages Adds image entries.
     * @includeHreflang Adds hreflang entries.
     * @includeVideos Adds video entries.
     */
    private string function buildUrlEntry(
        required struct data,
        string lastModFormat = "date",
        boolean includeImages = false,
        boolean includeHreflang = false,
        boolean includeVideos = false
    ) {
        var entry = '<url>';
        entry &= '<loc>#xmlFormat( arguments.data.url )#</loc>';
        // Write <lastmod> only when the crawler found a valid date.
        if ( isDate( arguments.data.lastModified ) ) {
            entry &= '<lastmod>#formatLastMod( arguments.data.lastModified, arguments.lastModFormat )#</lastmod>';
        }
        // Sitemap priority uses one decimal place.
        entry &= '<priority>#numberFormat( arguments.data.priority, "0.0" )#</priority>';
        // Add optional extension entries after the core sitemap fields.
        if ( arguments.includeHreflang && arguments.data.keyExists( "alternates" ) ) {
            for ( var alt in arguments.data.alternates ) {
                entry &= '<xhtml:link rel="alternate" hreflang="#xmlFormat( alt.hreflang )#" href="#xmlFormat( alt.href )#"/>';
            }
        }
        if ( arguments.includeImages && arguments.data.keyExists( "images" ) ) {
            for ( var img in arguments.data.images ) {
                entry &= '<image:image><image:loc>#xmlFormat( img )#</image:loc></image:image>';
            }
        }
        // Keep video fields in the order required by Google's schema.
        if ( arguments.includeVideos && arguments.data.keyExists( "videos" ) ) {
            for ( var video in arguments.data.videos ) {
                entry &= '<video:video>';
                entry &= '<video:thumbnail_loc>#xmlFormat( video.thumbnailLoc )#</video:thumbnail_loc>';
                entry &= '<video:title>#xmlFormat( video.title )#</video:title>';
                entry &= '<video:description>#xmlFormat( video.description )#</video:description>';
                if ( len( video.contentLoc ) ) {
                    entry &= '<video:content_loc>#xmlFormat( video.contentLoc )#</video:content_loc>';
                }
                if ( len( video.playerLoc ) ) {
                    entry &= '<video:player_loc>#xmlFormat( video.playerLoc )#</video:player_loc>';
                }
                // Caller-built page structs may not have duration.
                if ( video.keyExists( "duration" ) && val( video.duration ) > 0 ) {
                    entry &= '<video:duration>#int( val( video.duration ) )#</video:duration>';
                }
                entry &= '</video:video>';
            }
        }
        entry &= '</url>';
        return entry;
    }

    /**
     * urlsetOpenTag
     *
     * Returns the opening <urlset> tag with enabled extension namespaces.
     *
     * @includeImages Adds the image namespace.
     * @includeHreflang Adds the XHTML namespace.
     * @includeVideos Adds the video namespace.
     */
    private string function urlsetOpenTag(
        required boolean includeImages,
        boolean includeHreflang = false,
        boolean includeVideos = false
    ) {
        if ( !arguments.includeImages && !arguments.includeHreflang && !arguments.includeVideos ) {
            return variables.urlsetOpen;
        }
        var tag = '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"';
        if ( arguments.includeImages ) {
            tag &= ' xmlns:image="http://www.google.com/schemas/sitemap-image/1.1"';
        }
        if ( arguments.includeHreflang ) {
            tag &= ' xmlns:xhtml="http://www.w3.org/1999/xhtml"';
        }
        if ( arguments.includeVideos ) {
            tag &= ' xmlns:video="http://www.google.com/schemas/sitemap-video/1.1"';
        }
        return tag & '>';
    }

    /**
     * formatLastMod
     *
     * Formats a date for the <lastmod> element.
     *
     * @value Date object or date string.
     * @lastModFormat "date" for the date-only W3C form (YYYY-MM-DD), or "datetime"
     *   for the full W3C timestamp (YYYY-MM-DDThh:mm:ss+HH:MM).
     *
     * java.time is used for datetime output because BoxLang dates do not extend
     * java.util.Date. Lowercase xxx writes a zero offset as +00:00 instead of Z.
     */
    private string function formatLastMod( required any value, required string lastModFormat ) {
        if ( arguments.lastModFormat != "datetime" ) {
            return dateFormat( arguments.value, "yyyy-mm-dd" );
        }
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
     * childFilename
     *
     * Inserts a child number before the filename extension.
     *
     * @primaryFilename Primary sitemap filename.
     * @n One-based child number.
     */
    private string function childFilename( required string primaryFilename, required numeric n ) {
        if ( arguments.primaryFilename.reFind( "\.[^.]+$" ) ) {
            var ext  = arguments.primaryFilename.listLast( "." );
            var base = arguments.primaryFilename.left( arguments.primaryFilename.len() - ext.len() - 1 );
            return base & "-" & arguments.n & "." & ext;
        }
        return arguments.primaryFilename & "-" & arguments.n;
    }

    /**
     * byteLength
     *
     * Returns the UTF-8 byte length. CFML len() counts characters instead.
     *
     * @value String to measure.
     */
    private numeric function byteLength( required string value ) {
        return len( charsetDecode( arguments.value, "utf-8" ) );
    }

    /**
     * saveToFile
     *
     * Writes plain or gzip-compressed XML and creates missing parent directories.
     * GZIPOutputStream.finish() must run before reading the buffer or the gzip
     * trailer will be missing.
     *
     * @xml Sitemap XML.
     * @path Full destination path. A gzip path should end in .gz.
     * @gzip Compresses the XML before writing it.
     */
    function saveToFile( required string xml, required string path, boolean gzip = false ) {
        var dir = getDirectoryFromPath( arguments.path );
        if ( len( dir ) && !directoryExists( dir ) ) {
            // Java creates parent directories consistently on every CFML engine.
            createObject( "java", "java.io.File" ).init( javaCast( "string", dir ) ).mkdirs();
        }
        if ( arguments.gzip ) {
            var baos = createObject( "java", "java.io.ByteArrayOutputStream" ).init();
            var gz   = createObject( "java", "java.util.zip.GZIPOutputStream" ).init( baos );
            gz.write( charsetDecode( arguments.xml, "utf-8" ) );
            gz.finish();
            gz.close();
            fileWrite( arguments.path, baos.toByteArray() );
            return;
        }
        fileWrite( arguments.path, arguments.xml );
    }

}
