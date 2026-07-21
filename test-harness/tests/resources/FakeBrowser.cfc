/**
 * FakeBrowser
 * A test double for the real Jsoup browser. It lets CrawlerSpec drive a
 * multi-page breadth-first crawl without any real HTTP.
 *
 * It implements the same IBrowser.fetchUrl( url ) method the Crawler calls, and
 * returns the same struct shape the real models/browsers/Jsoup.cfc returns:
 *   { url, headers (struct), contentType, html (optional) }
 * The "html" key is only present for pages added with addPage(); leaving it out
 * makes the Crawler take its header-only path.
 *
 * Set up a page graph with addPage() and mark failures with failOn(). Every
 * fetchUrl() call is recorded in requestedUrls in call order, so a spec can
 * assert breadth-first visit order.
 *
 * It does not declare `implements="IBrowser"` because the interface lives in the
 * module's models/browsers folder and is not reachable by a mapping from here.
 * The Crawler only calls browser.fetchUrl(), so matching that one method is
 * enough.
 */
component {

    function init() {
        variables.pages        = {}; // url -> fetch-result struct
        variables.throwUrls    = {}; // url -> error message
        variables.requestedUrls = []; // every fetchUrl() call, in order
        variables.robotsContent = ""; // body returned by getText() (robots.txt)
        return this;
    }

    /**
     * addPage
     * Registers an HTML page the crawler can fetch.
     *
     * @url The absolute URL of the page.
     * @html The page body. Use absolute hrefs in <a> tags, because the Parser
     *       parses this html with no base URI, so only absolute hrefs resolve.
     * @headers Optional response headers (e.g. { "Last-Modified": "..." }).
     */
    function addPage( required string url, required string html, struct headers = {} ) {
        variables.pages[ arguments.url ] = {
            "url"         : arguments.url,
            "headers"     : arguments.headers,
            "contentType" : "text/html;charset=UTF-8",
            "html"        : arguments.html
        };
        return this;
    }

    /**
     * failOn
     * Makes fetchUrl() throw for the given URL, so the Crawler records it in
     * badUrls. Mirrors the StatusCodeException the real Jsoup browser throws on a
     * non-200 response.
     *
     * @url The URL that should fail.
     * @message The error message to throw.
     */
    function failOn( required string url, string message = "Failed to fetch #arguments.url#" ) {
        variables.throwUrls[ arguments.url ] = arguments.message;
        return this;
    }

    /**
     * fetchUrl
     * Returns the registered page struct for a URL, throws if the URL was marked
     * with failOn(), and records the call. Throws for any unregistered URL so a
     * spec fails loudly instead of silently crawling nothing.
     *
     * @url The URL to fetch.
     */
    any function fetchUrl( required string url ) {
        variables.requestedUrls.append( arguments.url );

        if ( variables.throwUrls.keyExists( arguments.url ) ) {
            throw( type = "StatusCodeException", message = variables.throwUrls[ arguments.url ] );
        }

        if ( variables.pages.keyExists( arguments.url ) ) {
            return variables.pages[ arguments.url ];
        }

        throw(
            type    = "FakeBrowser.UnknownUrl",
            message = "FakeBrowser has no page registered for #arguments.url#"
        );
    }

    /**
     * getRequestedUrls
     * Returns the URLs fetchUrl() was called with, in call order.
     */
    array function getRequestedUrls() {
        return variables.requestedUrls;
    }

    /**
     * setRobots
     * Registers the body getText() returns, so a spec can drive the Crawler's
     * robots.txt handling. When unset, getText() returns "" (no rules -> allow
     * all), matching a site with no robots.txt.
     *
     * @content The robots.txt body to serve.
     */
    function setRobots( required string content ) {
        variables.robotsContent = arguments.content;
        return this;
    }

    /**
     * getText
     * Returns the registered robots.txt body (empty by default). Mirrors the real
     * Jsoup browser's getText(), which the Crawler calls once at crawl start.
     *
     * @url The URL to fetch (ignored; this fake serves one robots body).
     */
    string function getText( required string url ) {
        return variables.robotsContent;
    }

}
