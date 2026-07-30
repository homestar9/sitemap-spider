interface {

    /**
     * fetchUrl
     *
     * Fetches a URL and returns url, headers, and contentType. HTML responses also
     * include html. A browser can include redirectChain with url and status steps.
     * Non-200 responses must throw StatusCodeException.
     *
     * A thrown StatusCodeException should set errorCode to the HTTP status and
     * extendedInfo to a JSON string with status, url, and chain keys. The crawler
     * reads those to tell a 404 from a 500 and to report the redirect steps that
     * led to the failure. Omitting them is safe: the crawler then records the URL
     * with status 0 and reason "unknown".
     *
     * @url URL to fetch.
     * @returns Fetch result struct.
     */
    any function fetchUrl( required string url );

    /**
     * checkUrl
     *
     * Requests only the status of a URL, without parsing or following its links.
     * The crawler uses this for images, stylesheets, scripts, and other files it
     * never crawls as pages.
     *
     * This must never throw. A transport failure returns ok=false, status=0, and a
     * message in error. Returns a struct with ok, status, url, redirectChain, and
     * error keys.
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
