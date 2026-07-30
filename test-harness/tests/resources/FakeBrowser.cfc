/**
 * FakeBrowser
 *
 * Returns configured fetch results without HTTP. Specs add pages or failures
 * and inspect requestedUrls to check fetch order.
 */
component {

    /**
     * init
     *
     * Creates empty fake response collections.
     */
    function init() {
        variables.pages        = {}; // url -> fetch-result struct
        variables.throwUrls    = {}; // url -> { message, status, chain }
        variables.requestedUrls = []; // every fetchUrl() call, in order
        variables.assets       = {}; // url -> status returned by checkUrl()
        variables.checkedUrls  = []; // every checkUrl() call, in order
        variables.robotsContent = ""; // body returned by getText() (robots.txt)
        variables.parallelSupported = true; // what supportsParallel() reports
        // Use one lock name to record parallel fetches safely.
        variables.recordLock   = "FakeBrowser-" & createUUID();
        return this;
    }

    /**
     * addPage
     *
     * Registers an HTML page the crawler can fetch.
     *
     * @url The absolute URL of the page.
     * @html Page body. Links must be absolute because Parser has no base URI.
     * @headers Optional response headers.
     * @finalUrl Final URL used to simulate a followed redirect.
     * @redirectChain Optional array of redirect steps.
     */
    function addPage(
        required string url,
        required string html,
        struct headers = {},
        string finalUrl = arguments.url,
        array redirectChain
    ) {
        var page = {
            "url"         : arguments.finalUrl,
            "headers"     : arguments.headers,
            "contentType" : "text/html;charset=UTF-8",
            "html"        : arguments.html
        };
        if ( !isNull( arguments.redirectChain ) ) {
            page[ "redirectChain" ] = arguments.redirectChain;
        }
        variables.pages[ arguments.url ] = page;
        return this;
    }

    /**
     * failOn
     *
     * Makes fetchUrl() throw for a URL. A status adds the errorCode and
     * extendedInfo fields that Crawler reads.
     *
     * @url The URL that should fail.
     * @message The error message to throw.
     * @status HTTP status. 0 stands for a connection failure with no response.
     * @chain Redirect steps to report, each with url and status keys.
     * @type Exception type. Use TooManyRedirectsException for a redirect loop.
     */
    function failOn(
        required string url,
        string message = "Failed to fetch #arguments.url#",
        numeric status = 0,
        array chain    = [],
        string type    = "StatusCodeException"
    ) {
        variables.throwUrls[ arguments.url ] = {
            "message" : arguments.message,
            "status"  : arguments.status,
            "chain"   : arguments.chain,
            "type"    : arguments.type
        };
        return this;
    }

    /**
     * addAsset
     *
     * Registers an asset status. Unregistered URLs return 404.
     *
     * @url The asset URL.
     * @status HTTP status to report.
     */
    function addAsset( required string url, numeric status = 200 ) {
        variables.assets[ arguments.url ] = arguments.status;
        return this;
    }

    /**
     * fetchUrl
     *
     * Records the request and returns its page or throws its configured error.
     *
     * @url The URL to fetch.
     */
    any function fetchUrl( required string url ) {
        // Guard the append: the parallel crawler calls this from several threads.
        lock name="#variables.recordLock#" type="exclusive" timeout="10" {
            variables.requestedUrls.append( arguments.url );
        }

        if ( variables.throwUrls.keyExists( arguments.url ) ) {
            var failure = variables.throwUrls[ arguments.url ];
            throw(
                type         = failure.type,
                message      = failure.message,
                errorCode    = failure.status,
                extendedInfo = serializeJSON( {
                    "status" : failure.status,
                    "url"    : arguments.url,
                    "chain"  : failure.chain
                } )
            );
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
     * checkUrl
     *
     * Records an asset check and returns its status without throwing.
     *
     * @url The asset URL to check.
     */
    struct function checkUrl( required string url ) {
        lock name="#variables.recordLock#" type="exclusive" timeout="10" {
            variables.checkedUrls.append( arguments.url );
        }

        var status = variables.assets.keyExists( arguments.url ) ? variables.assets[ arguments.url ] : 404;
        return {
            "ok"            : status >= 200 && status < 400,
            "status"        : status,
            "url"           : arguments.url,
            "redirectChain" : [],
            "error"         : status >= 400 ? "Asset request returned status code #status#" : ""
        };
    }

    /**
     * getCheckedUrls
     *
     * Returns the URLs passed to checkUrl().
     */
    array function getCheckedUrls() {
        lock name="#variables.recordLock#" type="exclusive" timeout="10" {
            return variables.checkedUrls;
        }
    }

    /**
     * getRequestedUrls
     *
     * Returns fetchUrl() calls in order for synchronous crawls. Parallel call
     * order is not reliable, so async specs compare the URL set.
     */
    array function getRequestedUrls() {
        lock name="#variables.recordLock#" type="exclusive" timeout="10" {
            return variables.requestedUrls;
        }
    }

    /**
     * setParallelSupported
     *
     * Sets the value returned by supportsParallel().
     *
     * @supported Whether supportsParallel() should return true.
     */
    function setParallelSupported( required boolean supported ) {
        variables.parallelSupported = arguments.supported;
        return this;
    }

    /**
     * supportsParallel
     *
     * Returns whether Crawler can call this fake from parallel workers.
     */
    boolean function supportsParallel() {
        return variables.parallelSupported;
    }

    /**
     * setRobots
     *
     * Sets the robots.txt body returned by getText(). Empty text allows all URLs.
     *
     * @content The robots.txt body to serve.
     */
    function setRobots( required string content ) {
        variables.robotsContent = arguments.content;
        return this;
    }

    /**
     * getText
     *
     * Returns the registered robots.txt body.
     *
     * @url The URL to fetch (ignored; this fake serves one robots body).
     */
    string function getText( required string url ) {
        return variables.robotsContent;
    }

    /**
     * shutdown
     *
     * Releases no resources because this fake does not open a browser.
     */
    void function shutdown() {
    }

}
