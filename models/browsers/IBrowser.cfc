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
     * - redirectChain: OPTIONAL. An array of { url, status } structs, one per hop,
     *   present only when the fetch followed one or more redirects. The first entry
     *   is the requested URL; the last is the final URL. A backend that does not
     *   track hops omits this key, so callers must check keyExists( "redirectChain" ).
     *
     * Throws a "StatusCodeException" when the response status is not 200, so the
     * Crawler can record the URL as bad and move on. A backend that enforces a
     * redirect hop-limit throws a "TooManyRedirectsException" when a chain is too
     * long, which the Crawler also records as a bad URL.
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

    /**
     * Reports whether this backend is safe to call from several crawl worker
     * threads at once.
     *
     * The Crawler only runs a parallel crawl when this returns true. A stateless
     * backend that builds a fresh request per fetch (jsoup) is safe and returns
     * true; a backend that reuses one shared browser page/context per crawl
     * (Playwright) is not thread-safe and returns false, so a parallel crawl with
     * that backend falls back to single-threaded.
     *
     * @returns boolean
     */
    boolean function supportsParallel();

}
