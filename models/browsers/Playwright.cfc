/**
 * Renders pages with Playwright so the crawler can see JavaScript content and
 * client-side redirects.
 *
 * This component uses cbPlaywright's launchBrowser() and navigate() helpers but
 * not its lifecycle methods. Those methods can rethrow a missing-super-method
 * error on BoxLang. initPlaywright() and shutdown() perform that work here.
 *
 * One Playwright instance, browser, context, and page are created on the first
 * fetch and reused for the crawl. Only their creating thread can use or close
 * them. The crawler therefore runs this backend on one thread and calls
 * shutdown() from that thread. Each concurrent crawl starts its own Node and
 * Chromium processes, so maxConcurrentJobs should remain low.
 *
 * A hard process kill can leave Chromium processes behind because no cleanup
 * code runs. During a ColdBox reinit, SitemapJobRegistry cancels the crawl and
 * its owning thread reaches shutdown().
 */
component
    extends="BaseBrowser"
    implements="IBrowser"
{

    property name="logger" inject="logbox:logger:{this}";

    include "/cbPlaywright/models/PlaywrightMixins.cfm";

    /**
     * fetchUrl
     *
     * Navigates to a URL, waits for JavaScript, and returns the rendered HTML.
     * Playwright controls redirects, so maxRedirects does not apply.
     *
     * @url URL to fetch.
     */
    any function fetchUrl( required string url ) {

        var page = getPage();
        // navigate() returns the main response for the page.
        var response = navigate( page, arguments.url );

        applyWaitStrategy( page );

        // An in-page navigation can have no response. Treat it as successful.
        var statusCode = 200;
        var headers = {};
        if ( !isNull( response ) ) {
            statusCode = response.status();
            headers = toHeaderStruct( response.allHeaders() );
        }

        // Build the chain before the status check so a failed response still
        // reports the redirect steps that led to it.
        var chain = buildRedirectChain( response );

        if ( statusCode != 200 ) {
            throw(
                message = "Failed to fetch #arguments.url# HTTP request returned status code #statusCode#",
                type = "StatusCodeException",
                errorCode    = statusCode,
                extendedInfo = serializeJSON( {
                    "status" : statusCode,
                    "url"    : page.url().toString(),
                    "chain"  : chain
                } )
            );
        }

        // Return the final URL and rendered DOM after any client-side redirect.
        var result = buildResult(
            url = page.url().toString(),
            headers = headers,
            contentType = "text/html",
            body = page.content()
        );

        if ( chain.len() > 1 ) {
            result[ "redirectChain" ] = chain;
        }
        return result;
    }

    /**
     * buildRedirectChain
     *
     * Returns redirect steps from the first request through the final response.
     *
     * @response Main navigation response, or null.
     */
    private array function buildRedirectChain( any response ) {
        if ( isNull( arguments.response ) ) {
            return [];
        }
        // redirectedFrom() walks from the newest request to the oldest.
        var reqs = [];
        var req  = arguments.response.request();
        while ( !isNull( req ) ) {
            reqs.append( req );
            req = req.redirectedFrom();
        }

        // Return the requests in fetch order with each response status.
        var chain = [];
        for ( var i = reqs.len(); i >= 1; i-- ) {
            var hopResponse = reqs[ i ].response();
            var status      = isNull( hopResponse ) ? 0 : hopResponse.status();
            chain.append( { "url" : reqs[ i ].url(), "status" : status } );
        }
        return chain;
    }

    /**
     * getText
     *
     * Returns raw text with a plain HTTP request so robots.txt does not start a browser.
     *
     * @url URL to fetch.
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
     * shutdown
     *
     * Closes Playwright resources and clears their cached handles. It is safe to
     * call before startup or more than once.
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
                variables.playwright.close();
            } catch ( any e ) {
                logger.warn( "Error closing Playwright: #e.message#" );
            }
            structDelete( variables, "playwright" );
        }
        structDelete( variables, "page" );
        structDelete( variables, "context" );
        structDelete( variables, "browserInstance" );
    }

    /**
     * supportsParallel
     *
     * Returns false because Playwright objects can only run on their creating
     * thread. The crawler must use this backend in single-threaded mode.
     */
    boolean function supportsParallel() {
        return false;
    }

    /**
     * getPage
     *
     * Returns the crawl's page. The first call creates Playwright, a browser,
     * a context, and the page.
     */
    private any function getPage() {
        if ( structKeyExists( variables, "page" ) ) {
            return variables.page;
        }
        if ( !structKeyExists( variables, "playwright" ) ) {
            initPlaywright();
        }
        variables.browserInstance = launchBrowser( variables.playwright.chromium(), true );
        variables.context = variables.browserInstance.newContext();
        variables.page = variables.context.newPage();
        return variables.page;
    }

    /**
     * initPlaywright
     *
     * Creates the Playwright instance without cbPlaywright's lifecycle method.
     * The lifecycle method fails on BoxLang when its super method is missing.
     * This method resolves the driver, verifies its version, and starts Playwright.
     */
    private void function initPlaywright() {
        var javaSystem = createObject( "java", "java.lang.System" );
        var expectedVersion = fileRead( expandPath( "/cbPlaywright/playwright.version" ) );

        var driverDir = javaSystem.getEnv( "CBPLAYWRIGHT_DRIVER_DIR" );
        if ( isNull( driverDir ) ) {
            var fileSeparator = javaSystem.getProperty( "file.separator" );
            driverDir = javaSystem.getProperty( "user.home" ) & fileSeparator & ".CommandBox" & fileSeparator
                & "cfml" & fileSeparator & "modules" & fileSeparator & "commandbox-cbplaywright" & fileSeparator & "driver";
        }
        if ( right( driverDir, 1 ) != "/" ) {
            driverDir &= "/";
        }
        if ( !directoryExists( driverDir ) ) {
            throw(
                message = "Playwright driver directory does not exist: [#driverDir#]",
                detail = "Install it with commandbox-cbplaywright, or point CBPLAYWRIGHT_DRIVER_DIR at an installed driver."
            );
        }

        var driverVersion = deserializeJSON( fileRead( driverDir & "package/package.json" ) ).version;
        if ( expectedVersion != driverVersion ) {
            throw(
                message = "Incompatible Playwright driver version. cbPlaywright expects [#expectedVersion#] but the driver is [#driverVersion#].",
                detail = "CommandBox users can run `cbplaywright driver install #expectedVersion# --force`."
            );
        }

        javaSystem.setProperty( "playwright.cli.dir", driverDir );
        var createOptions = createObject( "java", "com.microsoft.playwright.Playwright$CreateOptions" ).init();
        variables.playwright = createObject( "java", "com.microsoft.playwright.impl.PlaywrightImpl" ).create( createOptions );
    }

    /**
     * applyWaitStrategy
     *
     * Waits for the configured load state, optional selector, and optional fixed
     * delay. A selector timeout is logged and does not fail the fetch.
     *
     * @page Playwright page that finished navigation.
     */
    private void function applyWaitStrategy( required any page ) {
        var loadState = createObject( "java", "com.microsoft.playwright.options.LoadState" )[ uCase( settings.waitStrategy ) ];
        var waitOptions = createObject( "java", "com.microsoft.playwright.Page$WaitForLoadStateOptions" ).init();
        arguments.page.waitForLoadState( loadState, waitOptions );

        if ( len( settings.waitForSelector ) ) {
            try {
                var selectorOptions = createObject( "java", "com.microsoft.playwright.Page$WaitForSelectorOptions" )
                    .init()
                    .setTimeout( javaCast( "double", settings.requestTimeout ) );
                arguments.page.waitForSelector( settings.waitForSelector, selectorOptions );
            } catch ( any e ) {
                logger.warn( "waitForSelector '#settings.waitForSelector#' did not appear within #settings.requestTimeout#ms: #e.message#" );
            }
        }

        if ( settings.waitMs > 0 ) {
            sleep( settings.waitMs );
        }
    }

    /**
     * toHeaderStruct
     *
     * Copies Playwright response headers into a CFML struct.
     *
     * @headerMap Java map of response headers.
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
