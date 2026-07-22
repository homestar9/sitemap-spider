component {

    // XML envelope pieces shared by generate() and generateSet() so the
    // single-file output and each split chunk use byte-identical markup.
    variables.xmlHeader   = '<?xml version="1.0" encoding="UTF-8"?>';
    variables.urlsetOpen  = '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">';
    variables.urlsetClose = '</urlset>';
    variables.indexOpen   = '<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">';
    variables.indexClose  = '</sitemapindex>';

    function init() {
        return this;
    }

    /**
     * generate
     * Generate a single <urlset> XML sitemap for the given pages. Callers with a
     * page count/size that may exceed the sitemaps.org limits should use
     * generateSet(), which splits into child sitemaps plus an index.
     * todo: make sure it can handle images too
     *
     * @pages (required struct) pages to generate the sitemap for
     */
    function generate( required struct pages ) {
        var xml = variables.xmlHeader & variables.urlsetOpen;
        pages.each( ( pageUrl, data ) => {
            xml &= buildUrlEntry( pageUrl, data );
        } );
        xml &= variables.urlsetClose;
        return xml;
    }

    /**
     * generateSet
     * Generate a complete sitemap set, splitting into numbered child sitemaps
     * plus a <sitemapindex> when the pages exceed the sitemaps.org per-file
     * limits (URL count or uncompressed byte size). Below both limits the output
     * is a single <urlset>, byte-identical to generate().
     *
     * Returns one of:
     *   { type : "single", xml : <urlset xml>, sitemaps : [] }
     *   { type : "index",  xml : <sitemapindex xml>,
     *     sitemaps : [ { filename, xml, lastmod, urlCount }, ... ] }
     *
     * The <sitemapindex> <loc> for each child is publicBaseUrl & its filename,
     * so publicBaseUrl must be the absolute URL prefix the child files are served
     * from (e.g. "https://example.com/"). Child filenames are derived from
     * primaryFilename by inserting "-N" before the extension.
     *
     * @pages (required struct) pages to generate the sitemap for
     * @publicBaseUrl absolute URL prefix the child sitemaps are served from
     * @primaryFilename the index/single filename; children insert "-N" before its extension
     * @maxUrls per-file URL-count limit (sitemaps.org caps this at 50000)
     * @maxBytes per-file uncompressed byte limit (sitemaps.org caps this at 50 MiB)
     */
    function generateSet(
        required struct pages,
        string publicBaseUrl = "",
        string primaryFilename = "sitemap.xml",
        numeric maxUrls = 50000,
        numeric maxBytes = 52428800
    ) {
        // Byte size of an empty <urlset> file. Seeded into each chunk's running
        // total so the size check counts the envelope, not just the entries.
        var envelopeBytes = byteLength( variables.xmlHeader & variables.urlsetOpen & variables.urlsetClose );

        // Each chunk is { builder, count, bytes, lastMod }. builder holds the
        // <url> entries; count/bytes drive the split; lastMod is the newest page
        // date in the chunk, used for the index entry's <lastmod>.
        var chunks  = [];
        var current = ""; // becomes a struct once the first entry is placed

        for ( var pageUrl in arguments.pages ) {
            var data       = arguments.pages[ pageUrl ];
            var entry      = buildUrlEntry( pageUrl, data );
            var entryBytes = byteLength( entry );

            // Roll to a new chunk only when the current one already holds an
            // entry and adding this one would break a limit. The guards never
            // fire on an empty chunk, so a single oversized entry still gets its
            // own file instead of looping forever.
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

        // No pages, or one chunk: a single <urlset> file, no index.
        if ( chunks.len() <= 1 ) {
            var body = chunks.len() ? chunks[ 1 ].builder.toString() : "";
            return {
                type     : "single",
                xml      : variables.xmlHeader & variables.urlsetOpen & body & variables.urlsetClose,
                sitemaps : []
            };
        }

        // Multiple chunks: one child <urlset> file each, plus the <sitemapindex>.
        var sitemaps  = [];
        var indexBody = "";
        for ( var i = 1; i <= chunks.len(); i++ ) {
            var filename  = childFilename( arguments.primaryFilename, i );
            var childXml  = variables.xmlHeader & variables.urlsetOpen & chunks[ i ].builder.toString() & variables.urlsetClose;
            var hasDate   = isDate( chunks[ i ].lastMod );
            var lastModStr = hasDate ? dateFormat( chunks[ i ].lastMod, "yyyy-mm-dd" ) : "";

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
     * Build the <url>...</url> markup for one page. Shared by generate() and
     * generateSet() so both emit identical entries.
     *
     * @url the page URL (used as the <loc>)
     * @data the page struct with lastModified and priority keys
     */
    private string function buildUrlEntry( required string url, required struct data ) {
        var entry = '<url>';
        entry &= '<loc>#xmlFormat( arguments.url )#</loc>';
        // The sitemaps.org protocol requires W3C datetime for <lastmod>.
        // Emit the date-only form (YYYY-MM-DD), the shortest valid W3C form,
        // and only when a real date was recorded. dateFormat (not
        // dateTimeFormat) is used so the "mm" mask means month on every
        // engine; dateTimeFormat's "mm" means minutes on some engines.
        if ( isDate( arguments.data.lastModified ) ) {
            entry &= '<lastmod>#dateFormat( arguments.data.lastModified, "yyyy-mm-dd" )#</lastmod>';
        }
        // Priority is a value from 0.0 to 1.0; render one decimal place.
        entry &= '<priority>#numberFormat( arguments.data.priority, "0.0" )#</priority>';
        entry &= '</url>';
        return entry;
    }

    /**
     * childFilename
     * Build a numbered child filename from the primary filename by inserting
     * "-N" before the extension ("sitemap.xml", 1 -> "sitemap-1.xml"). A name
     * with no extension gets "-N" appended ("sitemap", 1 -> "sitemap-1").
     *
     * @primaryFilename the base filename (index/single file name)
     * @n the 1-based child number
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
     * Return the UTF-8 byte length of a string. Used for the per-file byte limit
     * because CFML len() counts characters, which undercounts multi-byte URLs.
     *
     * @value the string to measure
     */
    private numeric function byteLength( required string value ) {
        return len( charsetDecode( arguments.value, "utf-8" ) );
    }

    /**
     * Writes the sitemap XML to a file, creating the parent directory when it
     * does not already exist.
     * @xml The sitemap XML string to write.
     * @path The full file path to write to.
     */
    function saveToFile( required string xml, required string path ) {
        var dir = getDirectoryFromPath( arguments.path );
        if ( len( dir ) && !directoryExists( dir ) ) {
            // Java's File.mkdirs() creates any missing intermediate directories
            // and is used here because CFML's directoryCreate() signature differs
            // across engines (Adobe's takes only the path).
            createObject( "java", "java.io.File" ).init( javaCast( "string", dir ) ).mkdirs();
        }
        fileWrite( arguments.path, arguments.xml );
    }

}
