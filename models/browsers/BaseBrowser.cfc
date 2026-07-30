component {

    property name="settings" inject="coldbox:moduleSettings:sitemap-spider";

    /**
     * buildResult
     *
     * Builds the common fetch result used by every browser backend. It includes
     * body as html only for an HTML or XHTML response.
     *
     * @url Final URL after redirects.
     * @headers Response headers.
     * @contentType Content-Type response header.
     * @body Optional response body.
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
     * shutdown
     *
     * Releases resources after a crawl. Stateless browsers inherit this no-op.
     */
    void function shutdown() {
    }

    /**
     * supportsParallel
     *
     * Returns whether several crawl workers can call this browser at once.
     */
    boolean function supportsParallel() {
        return true;
    }

    /**
     * isHtmlContentType
     *
     * Returns whether contentType matches the configured HTML pattern.
     */
    private function isHtmlContentType( required string contentType ) {
        return !!( reMatchNoCase( settings.htmlContentTypePattern, contentType ).len() );
    }
}
