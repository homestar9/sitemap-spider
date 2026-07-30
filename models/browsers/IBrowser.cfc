interface {

    /**
     * fetchUrl
     *
     * Fetches a URL. Returns url, headers, and contentType, plus html for HTML
     * responses. redirectChain can contain url and status steps.
     *
     * Non-200 responses must throw StatusCodeException. errorCode should contain
     * the HTTP status. extendedInfo should contain JSON status, url, and chain
     * keys. Missing details produce status 0 and reason "unknown".
     *
     * @url URL to fetch.
     * @returns Fetch result struct.
     */
    any function fetchUrl( required string url );

    /**
     * checkUrl
     *
     * Checks an asset without parsing it. Returns ok, status, url, redirectChain,
     * and error. This method must not throw. Transport failures return ok=false,
     * status=0, and the message in error.
     *
     * @url URL to check.
     * @returns Check result struct.
     */
    struct function checkUrl( required string url );

    /**
     * getText
     *
     * Returns the raw response body regardless of content type. A non-200
     * response must throw so the crawler can treat robots.txt as missing.
     *
     * @url URL to fetch.
     * @returns Response body.
     */
    string function getText( required string url );

    /**
     * shutdown
     *
     * Releases resources after a crawl. It must be safe before initialization
     * and after an earlier shutdown.
     */
    void function shutdown();

    /**
     * supportsParallel
     *
     * Returns whether several crawl workers can call this browser at once.
     *
     * @returns boolean
     */
    boolean function supportsParallel();

}
