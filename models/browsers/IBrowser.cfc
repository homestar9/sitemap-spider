interface {

    /**
     * fetchUrl
     *
     * Fetches a URL and returns url, headers, and contentType. HTML responses also
     * include html. A browser can include redirectChain with url and status steps.
     * Non-200 responses must throw StatusCodeException.
     *
     * @url URL to fetch.
     * @returns Fetch result struct.
     */
    any function fetchUrl( required string url );

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
