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
     *
     * @pages (required array) page structs to generate the sitemap for, each with
     *   a url field plus lastModified, priority, and (when includeImages) images
     * @lastModFormat "date" for date-only <lastmod> (default), "datetime" for the
     *   full W3C timestamp. See formatLastMod.
     * @includeImages when true, each page's images array is emitted as
     *   <image:image> entries and the <urlset> gains the image namespace. Must
     *   match the value used to build the page structs; false keeps the output
     *   byte-identical to the pre-image behavior.
     */
    function generate(
        required array pages,
        string lastModFormat = "date",
        boolean includeImages = false
    ) {
        var xml = variables.xmlHeader & urlsetOpenTag( arguments.includeImages );
        for ( var data in arguments.pages ) {
            xml &= buildUrlEntry( data, lastModFormat, includeImages );
        }
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
     * @pages (required array) page structs to generate the sitemap for, each with
     *   a url field plus lastModified, priority, and (when includeImages) images
     * @publicBaseUrl absolute URL prefix the child sitemaps are served from
     * @primaryFilename the index/single filename; children insert "-N" before its extension
     * @maxUrls per-file URL-count limit (sitemaps.org caps this at 50000)
     * @maxBytes per-file uncompressed byte limit (sitemaps.org caps this at 50 MiB)
     * @gzip when true, child filenames and the index <loc> entries get a ".gz"
     *   suffix (e.g. "sitemap-1.xml.gz"), because the caller writes the child
     *   files gzip-compressed. The child xml strings stay uncompressed text.
     * @lastModFormat "date" (default) or "datetime"; passed through to each entry
     *   and used for the index <lastmod>. See formatLastMod.
     * @includeImages passed through to each entry and used for the <urlset>
     *   envelope tag and byte accounting. See generate.
     */
    function generateSet(
        required array pages,
        string publicBaseUrl = "",
        string primaryFilename = "sitemap.xml",
        numeric maxUrls = 50000,
        numeric maxBytes = 52428800,
        boolean gzip = false,
        string lastModFormat = "date",
        boolean includeImages = false
    ) {
        // The <urlset> envelope for this set, chosen once so every chunk and the
        // byte accounting below use the same open tag.
        var urlsetOpen = urlsetOpenTag( arguments.includeImages );

        // Byte size of an empty <urlset> file. Seeded into each chunk's running
        // total so the size check counts the envelope, not just the entries.
        var envelopeBytes = byteLength( variables.xmlHeader & urlsetOpen & variables.urlsetClose );

        // Each chunk is { builder, count, bytes, lastMod }. builder holds the
        // <url> entries; count/bytes drive the split; lastMod is the newest page
        // date in the chunk, used for the index entry's <lastmod>.
        var chunks  = [];
        var current = ""; // becomes a struct once the first entry is placed

        for ( var data in arguments.pages ) {
            var entry      = buildUrlEntry( data, arguments.lastModFormat, arguments.includeImages );
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
                xml      : variables.xmlHeader & urlsetOpen & body & variables.urlsetClose,
                sitemaps : []
            };
        }

        // Multiple chunks: one child <urlset> file each, plus the <sitemapindex>.
        var sitemaps  = [];
        var indexBody = "";
        for ( var i = 1; i <= chunks.len(); i++ ) {
            // childFilename builds "sitemap-N.xml"; the ".gz" is appended after so
            // childFilename's single-extension logic is never fed "sitemap.xml.gz".
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
     * Build the <url>...</url> markup for one page. Shared by generate() and
     * generateSet() so both emit identical entries.
     *
     * @data the page struct with url, lastModified, and priority keys (and images
     *   when includeImages is on). The url field becomes the <loc>.
     * @lastModFormat "date" or "datetime" for the <lastmod> element
     * @includeImages when true, emit an <image:image> for each URL in data.images
     */
    private string function buildUrlEntry(
        required struct data,
        string lastModFormat = "date",
        boolean includeImages = false
    ) {
        var entry = '<url>';
        entry &= '<loc>#xmlFormat( arguments.data.url )#</loc>';
        // The sitemaps.org protocol requires W3C datetime for <lastmod>. Emit it
        // only when a real date was recorded; formatLastMod picks date-only or the
        // full timestamp based on lastModFormat.
        if ( isDate( arguments.data.lastModified ) ) {
            entry &= '<lastmod>#formatLastMod( arguments.data.lastModified, arguments.lastModFormat )#</lastmod>';
        }
        // Priority is a value from 0.0 to 1.0; render one decimal place.
        entry &= '<priority>#numberFormat( arguments.data.priority, "0.0" )#</priority>';
        // Image-extension entries come after the core sitemaps.org sequence
        // (loc, lastmod, priority), so the core element order stays valid. Guard
        // on the images key because callers may build page structs without it.
        if ( arguments.includeImages && arguments.data.keyExists( "images" ) ) {
            for ( var img in arguments.data.images ) {
                entry &= '<image:image><image:loc>#xmlFormat( img )#</image:loc></image:image>';
            }
        }
        entry &= '</url>';
        return entry;
    }

    /**
     * urlsetOpenTag
     * Return the opening <urlset> tag. The image-extension namespace is added
     * only when includeImages is true, so a normal crawl's output stays
     * byte-for-byte the same as before this feature existed.
     *
     * @includeImages whether the sitemap emits <image:image> entries
     */
    private string function urlsetOpenTag( required boolean includeImages ) {
        return arguments.includeImages
            ? '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:image="http://www.google.com/schemas/sitemap-image/1.1">'
            : variables.urlsetOpen;
    }

    /**
     * formatLastMod
     * Format a last-modified date for the <lastmod> element.
     *
     * @value a date object, or a date string like "2026-07-20"
     * @lastModFormat "date" for the date-only W3C form (YYYY-MM-DD), or "datetime"
     *   for the full W3C timestamp (YYYY-MM-DDThh:mm:ss+HH:MM).
     *
     * The date-only path uses dateFormat (not dateTimeFormat) so the "mm" mask
     * means month on every engine. The datetime path builds a java.time value
     * from CFML date-part functions (year/month/day/hour/minute/second), which
     * accept both a date object and a plain date string on Adobe, Lucee, and
     * BoxLang. It avoids date.getTime() because BoxLang's date type is not a
     * java.util.Date subclass. The offset is the server's local timezone (the
     * same zone the date-only form is rendered in), computed DST-correct for the
     * given date. Pattern letter lowercase "xxx" renders a zero offset as
     * "+00:00"; uppercase "XXX" would render it as "Z".
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
     * @gzip When true, the XML is gzip-compressed before it is written. The
     *   caller is responsible for giving @path a ".gz" name.
     *
     * The gzip path compresses into an in-memory buffer, then reuses the same
     * fileWrite as the plain path. charsetDecode returns a UTF-8 byte array on
     * every engine, and GZIPOutputStream.finish() must run before the buffer is
     * read so the gzip trailer is included.
     */
    function saveToFile( required string xml, required string path, boolean gzip = false ) {
        var dir = getDirectoryFromPath( arguments.path );
        if ( len( dir ) && !directoryExists( dir ) ) {
            // Java's File.mkdirs() creates any missing intermediate directories
            // and is used here because CFML's directoryCreate() signature differs
            // across engines (Adobe's takes only the path).
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
