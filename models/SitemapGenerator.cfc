component {

    function init() {
        return this;
    }

    /**
     * generate
     * Generate the XML Sitemap
     * todo: make sure it can handle images too
     * 
     * @pages (required struct) pages to generate the sitemap for
     */
    function generate( required struct pages ) {
        var xml = '<?xml version="1.0" encoding="UTF-8"?>';
        xml &= '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">';
        pages.each((url, data) => {
            xml &= '<url>';
            xml &= '<loc>#xmlFormat( arguments.url )#</loc>';
            // The sitemaps.org protocol requires W3C datetime for <lastmod>.
            // Emit the date-only form (YYYY-MM-DD), the shortest valid W3C form,
            // and only when a real date was recorded. dateFormat (not
            // dateTimeFormat) is used so the "mm" mask means month on every
            // engine; dateTimeFormat's "mm" means minutes on some engines.
            if ( isDate( data.lastModified ) ) {
                xml &= '<lastmod>#dateFormat( data.lastModified, "yyyy-mm-dd" )#</lastmod>';
            }
            // Priority is a value from 0.0 to 1.0; render one decimal place.
            xml &= '<priority>#numberFormat( data.priority, "0.0" )#</priority>';
            xml &= '</url>';
        });
        xml &= '</urlset>';
        return xml;
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