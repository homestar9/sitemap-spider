component {

    property name="settings" inject="coldbox:moduleSettings:sitemap-spider";

    /**
     * Assembles the struct that fetchUrl returns, shared by every backend.
     * @url The final URL after any redirect the backend followed.
     * @headers A struct of response headers (name -> value string).
     * @contentType The response Content-Type header value.
     * @body The response body. Optional. It is added to the result under the
     *       "html" key ONLY when it is provided and the content type is HTML or
     *       XHTML, so callers never parse a non-HTML body (e.g. a PDF or image).
     *
     * Each backend extracts headers its own way (jsoup exposes a multi-value Java
     * map, Playwright a flat one), then calls this to build the same result shape.
     */
    struct function buildResult(
        required string url,
        required struct headers,
        required string contentType,
        string body
    ) {
        var result = {
            url = arguments.url,
            headers = arguments.headers,
            contentType = arguments.contentType
        };
        if ( !isNull( arguments.body ) && isHtmlContentType( arguments.contentType ) ) {
            result.html = arguments.body;
        }
        return result;
    }

    /**
     * Releases any resources the backend holds for a crawl. Stateless backends
     * (jsoup) inherit this no-op; a backend with a live browser overrides it.
     */
    void function shutdown() {
    }

    private function isHtmlContentType( required string contentType ) {
        // Check if the content type is in the allowed HTML content types
        return !!( reMatchNoCase( settings.htmlContentTypePattern, contentType ).len() );
    }
}
