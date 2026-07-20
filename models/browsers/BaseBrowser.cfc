component {

    property name="settings" inject="coldbox:moduleSettings:sitemap-spider";

    private function isHtmlContentType( required string contentType ) {
        // Check if the content type is in the allowed HTML content types
        return !!( reMatchNoCase( settings.htmlContentTypePattern, contentType ).len() );
    }
}