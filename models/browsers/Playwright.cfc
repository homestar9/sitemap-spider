/**
 * Browser backend that renders pages with a real headless browser (Playwright),
 * so JavaScript-injected links and client-side redirects are visible to the
 * crawler. Selected by setting the browserDsl module setting to
 * "Playwright@sitemap-spider".
 *
 * The cbPlaywright helper mixin is included below. It owns the Playwright
 * lifecycle: beforeAll() resolves the browser driver, checks the driver version
 * against cbPlaywright's playwright.version, and creates variables.playwright;
 * afterAll() closes it. launchBrowser() and navigate() wrap the Java option
 * objects. This backend adds only the crawl-specific parts: a configurable wait
 * for JavaScript, the result-struct shape, and robots.txt fetching. Using the
 * mixin needs a "/cbPlaywright" mapping and the Playwright jars on the class path;
 * the host Application.cfc sets both (see the test-harness Application.cfc).
 *
 * Lifecycle: the Playwright instance, one browser, one context, and one page are
 * created lazily on the first fetch and reused for the whole crawl (each fetch
 * navigates the same page). The Crawler calls shutdown() when the crawl finishes
 * to close the browser and stop the driver process.
 */
component
    extends="BaseBrowser"
    implements="IBrowser"
{

    property name="logger" inject="logbox:logger:{this}";

    include "/cbPlaywright/models/PlaywrightMixins.cfm";

    /**
     * Fetches a URL with a headless browser and returns the rendered page.
     * @url The URL to fetch
     *
     * Navigates to the URL, waits for the page per the waitStrategy/waitMs
     * settings so late JavaScript can run, then returns the rendered HTML and the
     * final URL (which reflects any client-side redirect). Throws a
     * StatusCodeException on a non-200 navigation response, matching the Jsoup
     * backend so the Crawler records the URL as bad.
     */
    any function fetchUrl( required string url ) {

        var page = getPage();
        // navigate() is a cbPlaywright mixin helper; it returns the main response.
        var response = navigate( page, arguments.url );

        applyWaitStrategy( page );

        // response is null for a navigation that does not produce a main response
        // (e.g. an in-page anchor). Treat that as a 200 and read the headers from
        // the response only when present.
        var statusCode = 200;
        var headers = {};
        if ( !isNull( response ) ) {
            statusCode = response.status();
            headers = toHeaderStruct( response.allHeaders() );
        }

        if ( statusCode != 200 ) {
            throw(
                message = "Failed to fetch #arguments.url# HTTP request returned status code #statusCode#",
                type = "StatusCodeException"
            );
        }

        // page.url() is the final URL after any client-side (JavaScript) redirect;
        // page.content() is the rendered DOM after the wait. The content type is
        // always HTML here because a browser navigation only yields a document, so
        // buildResult includes the body under "html".
        return buildResult(
            url = page.url().toString(),
            headers = headers,
            contentType = "text/html",
            body = page.content()
        );
    }

    /**
     * Fetches the raw text body of a URL with a plain HTTP GET.
     * @url The URL to fetch
     *
     * Used for robots.txt, which is text/plain and needs no JavaScript, so this
     * avoids the browser. Throws a StatusCodeException on a non-200 so the Crawler
     * falls back to allow-all.
     */
    string function getText( required string url ) {
        var httpResult = "";
        cfhttp( url = arguments.url, method = "GET", result = "httpResult", timeout = int( settings.requestTimeout / 1000 ), useragent = settings.userAgent );

        if ( !httpResult.keyExists( "responseHeader" ) || httpResult.responseHeader.status_code != 200 ) {
            var code = httpResult.keyExists( "responseHeader" ) && httpResult.responseHeader.keyExists( "status_code" )
                ? httpResult.responseHeader.status_code
                : "unknown";
            throw(
                message = "Failed to fetch #arguments.url# HTTP request returned status code #code#",
                type = "StatusCodeException"
            );
        }

        return httpResult.fileContent;
    }

    /**
     * Closes the browser and stops the Playwright driver process. Called by the
     * Crawler when a crawl finishes. Safe to call when nothing was started and
     * safe to call more than once; clears the cached handles so a later crawl on
     * the same instance re-initializes.
     *
     * afterAll() is the cbPlaywright mixin helper that closes variables.playwright.
     */
    void function shutdown() {
        if ( structKeyExists( variables, "browserInstance" ) ) {
            try {
                variables.browserInstance.close();
            } catch ( any e ) {
                logger.warn( "Error closing Playwright browser: #e.message#" );
            }
        }
        if ( structKeyExists( variables, "playwright" ) ) {
            try {
                afterAll();
            } catch ( any e ) {
                logger.warn( "Error closing Playwright: #e.message#" );
            }
        }
        structDelete( variables, "page" );
        structDelete( variables, "context" );
        structDelete( variables, "browserInstance" );
    }

    /**
     * Reports that this backend is not safe for parallel crawling. It reuses one
     * shared browser page and context for the whole crawl (see getPage), and a
     * Playwright page/context cannot be driven from several threads at once. The
     * Crawler downgrades a runAsync crawl to single-threaded when this is false.
     */
    boolean function supportsParallel() {
        return false;
    }

    /**
     * Returns the shared page, creating the Playwright instance, a headless
     * browser, a context, and one page on first use. All are reused for the whole
     * crawl; each fetch navigates the same page.
     *
     * beforeAll() and launchBrowser() are cbPlaywright mixin helpers. beforeAll()
     * throws a clear error when the driver is missing or its version does not
     * match cbPlaywright, which is the "optional dependency not installed" signal.
     */
    private any function getPage() {
        if ( structKeyExists( variables, "page" ) ) {
            return variables.page;
        }
        if ( !structKeyExists( variables, "playwright" ) ) {
            beforeAll();
        }
        variables.browserInstance = launchBrowser( variables.playwright.chromium(), true );
        variables.context = variables.browserInstance.newContext();
        variables.page = variables.context.newPage();
        return variables.page;
    }

    /**
     * Waits for the page after navigation so JavaScript can finish.
     * @page A com.microsoft.playwright.Page
     *
     * First waits for the configured load state (settings.waitStrategy, "load" or
     * "networkidle"), then sleeps settings.waitMs. The fixed wait is needed for
     * content injected by a setTimeout with no network activity, which a load
     * state alone does not catch. The mixin's own waitForLoadState() only supports
     * "load", so this calls the Playwright API directly to allow "networkidle".
     */
    private void function applyWaitStrategy( required any page ) {
        var loadState = createObject( "java", "com.microsoft.playwright.options.LoadState" )[ uCase( settings.waitStrategy ) ];
        var waitOptions = createObject( "java", "com.microsoft.playwright.Page$WaitForLoadStateOptions" ).init();
        arguments.page.waitForLoadState( loadState, waitOptions );

        if ( settings.waitMs > 0 ) {
            sleep( settings.waitMs );
        }
    }

    /**
     * Converts a Playwright headers map (java.util.Map<String,String>) to a CF
     * struct. Iterates entrySet with an isNull guard, the portable pattern the
     * Jsoup backend uses.
     * @headerMap A java.util.Map of response headers
     */
    private struct function toHeaderStruct( required any headerMap ) {
        var result = {};
        var iterator = arguments.headerMap.entrySet().iterator();
        while ( iterator.hasNext() ) {
            var entry = iterator.next();
            var key = entry.getKey();
            var value = entry.getValue();
            if ( isNull( key ) || isNull( value ) ) {
                continue;
            }
            result[ key ] = value;
        }
        return result;
    }

}
