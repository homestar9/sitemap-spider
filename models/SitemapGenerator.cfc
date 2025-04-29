component {

    function init() {
        return this;
    }

    /**
     * generate
     * Generate the XML Sitemap
     * 
     * @pages (required struct) pages to generate the sitemap for
     */
    function generate( required struct pages ) {
        var xml = '<?xml version="1.0" encoding="UTF-8"?>';
        xml &= '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">';
        pages.each((url, data) => {
            xml &= '<url>';
            xml &= '<loc>#xmlFormat( arguments.url )#</loc>';
            if (len(data.lastModified)) {
                xml &= '<lastmod>#data.lastModified#</lastmod>';
            }
            xml &= '<priority>#data.priority#</priority>';
            xml &= '</url>';
        });
        xml &= '</urlset>';
        return xml;
    }

    function saveToFile( required string xml, required string path ) {
        fileWrite( arguments.path, arguments.xml );
    }

}