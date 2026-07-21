/**
 * Browser backend that renders pages with a real headless browser (Playwright),
 * so JavaScript-injected links and client-side redirects are visible to the
 * crawler. Selected by setting the browserDsl module setting to
 * "Playwright@sitemap-spider".
 *
 * This backend uses the Playwright Java API directly. The cbPlaywright module is
 * only the delivery vehicle for the Playwright jars and the browser driver; the
 * jars are put on the CF class path by the host Application.cfc (see the
 * test-harness Application.cfc for the pattern), and the driver is installed by
 * commandbox-cbplaywright.
 *
 * Lifecycle: the Playwright instance, one browser, and one browser context are
 * created lazily on the first fetch and reused for the whole crawl. Each fetch
 * opens and closes its own page. The Crawler calls shutdown() when the crawl
 * finishes to close the browser and stop the driver process.
 */
component
    extends="BaseBrowser"
    implements="IBrowser"
{

    property name="logger" inject="logbox:logger:{this}";

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

        var page = getContext().newPage();

        try {
            var navOptions = createObject( "java", "com.microsoft.playwright.Page$NavigateOptions" ).init();
            var response = page.navigate( javaCast( "string", arguments.url ), navOptions );

            applyWaitStrategy( page );

            // response is null for a navigation that does not produce a main
            // response (e.g. an in-page anchor). Treat that as a 200 and read the
            // headers from the response only when present.
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

            // page.url() is the final URL after any client-side (JavaScript)
            // redirect; page.content() is the rendered DOM after the wait. The
            // content type is always HTML here because a browser navigation only
            // yields a document, so buildResult includes the body under "html".
            return buildResult(
                url = page.url().toString(),
                headers = headers,
                contentType = "text/html",
                body = page.content()
            );
        } finally {
            page.close();
        }
    }

    /**
     * Fetches the raw text body of a URL with a plain HTTP GET.
     * @url The URL to fetch
     *
     * Used for robots.txt, which is text/plain and needs no JavaScript, so this
     * avoids launching the browser. Throws a StatusCodeException on a non-200 so
     * the Crawler falls back to allow-all.
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
     */
    void function shutdown() {
        try {
            if ( structKeyExists( variables, "context" ) ) {
                variables.context.close();
            }
            if ( structKeyExists( variables, "browser" ) ) {
                variables.browser.close();
            }
            if ( structKeyExists( variables, "playwright" ) ) {
                variables.playwright.close();
            }
        } catch ( any e ) {
            // A cleanup failure must not mask the crawl result.
            logger.warn( "Error shutting down Playwright: #e.message#" );
        }
        structDelete( variables, "context" );
        structDelete( variables, "browser" );
        structDelete( variables, "playwright" );
    }

    /**
     * Lets a test inject an already-created Playwright instance so it does not
     * start a second driver process. Production code never calls this; the
     * instance is created lazily by getPlaywright().
     * @playwright A com.microsoft.playwright.Playwright instance
     */
    void function setPlaywright( required any playwright ) {
        variables.playwright = arguments.playwright;
    }

    /**
     * Returns the shared browser context, creating the Playwright instance, a
     * headless browser, and one context on first use. All three are reused for
     * the whole crawl.
     */
    private any function getContext() {
        if ( structKeyExists( variables, "context" ) ) {
            return variables.context;
        }
        if ( !structKeyExists( variables, "browser" ) ) {
            var launchOptions = createObject( "java", "com.microsoft.playwright.BrowserType$LaunchOptions" ).init();
            launchOptions.setHeadless( javaCast( "boolean", true ) );
            variables.browser = getPlaywright().chromium().launch( launchOptions );
        }
        variables.context = variables.browser.newContext();
        return variables.context;
    }

    /**
     * Creates and caches the Playwright Java instance.
     *
     * Resolves the browser driver directory (from the CBPLAYWRIGHT_DRIVER_DIR
     * environment variable, or the default location commandbox-cbplaywright
     * installs to), points Playwright at it with the playwright.cli.dir system
     * property, then creates the instance. Throws a clear configuration error
     * when the driver is missing, because cbPlaywright is an optional dependency
     * that this backend needs.
     */
    private any function getPlaywright() {
        if ( structKeyExists( variables, "playwright" ) ) {
            return variables.playwright;
        }

        var javaSystem = createObject( "java", "java.lang.System" );
        var driverDir = resolveDriverDir( javaSystem );

        if ( !directoryExists( driverDir ) ) {
            throw(
                type = "PlaywrightConfigurationException",
                message = "The Playwright browser backend is selected but its driver was not found at [#driverDir#].",
                detail = "Install cbPlaywright in the app and run the commandbox-cbplaywright driver install for version matching cbPlaywright, or set the CBPLAYWRIGHT_DRIVER_DIR environment variable to the driver directory."
            );
        }

        javaSystem.setProperty( "playwright.cli.dir", driverDir );
        var createOptions = createObject( "java", "com.microsoft.playwright.Playwright$CreateOptions" ).init();
        variables.playwright = createObject( "java", "com.microsoft.playwright.impl.PlaywrightImpl" ).create( createOptions );
        return variables.playwright;
    }

    /**
     * Returns the browser driver directory, ending with a slash. Uses
     * CBPLAYWRIGHT_DRIVER_DIR when set, else the path commandbox-cbplaywright
     * installs to under the user's home. Mirrors cbPlaywright's own resolution.
     * @javaSystem A java.lang.System instance
     */
    private string function resolveDriverDir( required any javaSystem ) {
        var driverDir = arguments.javaSystem.getEnv( "CBPLAYWRIGHT_DRIVER_DIR" );
        if ( isNull( driverDir ) ) {
            var userHome = arguments.javaSystem.getProperty( "user.home" );
            var fs = arguments.javaSystem.getProperty( "file.separator" );
            driverDir = userHome & fs & ".CommandBox" & fs & "cfml" & fs & "modules" & fs & "commandbox-cbplaywright" & fs & "driver";
        }
        if ( right( driverDir, 1 ) != "/" ) {
            driverDir &= "/";
        }
        return driverDir;
    }

    /**
     * Waits for the page after navigation so JavaScript can finish.
     * @page A com.microsoft.playwright.Page
     *
     * First waits for the configured load state (settings.waitStrategy, "load" or
     * "networkidle"), then sleeps settings.waitMs. The fixed wait is needed for
     * content injected by a setTimeout with no network activity, which a load
     * state alone does not catch.
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
