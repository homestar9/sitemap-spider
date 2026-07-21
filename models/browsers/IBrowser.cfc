interface {

    /**
     * Fetches a URL and returns its content and metadata.
     * @url The URL to fetch
     *
     * Returns a struct describing the fetched page:
     * - url: the final URL after any redirect the backend follows (jsoup follows
     *   HTTP 30x; the Playwright backend also follows client-side JS redirects).
     *   May differ from the requested url.
     * - headers: a struct of response headers (name -> value string).
     * - contentType: the response Content-Type header value.
     * - html: the response body, present ONLY when the content type is HTML or
     *   XHTML (see BaseBrowser.isHtmlContentType). Omitted for other types, so
     *   callers must check keyExists( "html" ) before reading it.
     *
     * Throws a "StatusCodeException" when the response status is not 200, so the
     * Crawler can record the URL as bad and move on.
     *
     * @returns struct
     */
    any function fetchUrl( required string url );

    /**
     * Fetches the raw text body of a URL, regardless of content type.
     * Used for robots.txt, which is served as text/plain and so is not returned
     * by fetchUrl (which only includes a body for HTML). Throws on a non-200
     * response so the caller can treat a missing robots.txt as "allow all".
     * @url The URL to fetch
     *
     * @returns string (the response body)
     */
    string function getText( required string url );

    /**
     * Releases any resources the backend holds for a crawl.
     *
     * The Crawler calls this once when a crawl finishes (in a finally block).
     * Stateless backends (jsoup) implement it as a no-op; a backend that holds a
     * live browser process (Playwright) closes it here. Must be safe to call even
     * if the backend was never used, and safe to call more than once.
     */
    void function shutdown();

}
