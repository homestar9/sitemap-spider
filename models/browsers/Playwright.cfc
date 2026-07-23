/**
 * Browser backend that renders pages with a real headless browser (Playwright),
 * so JavaScript-injected links and client-side redirects are visible to the
 * crawler. Selected by setting the browserDsl module setting to
 * "Playwright@sitemap-spider".
 *
 * The cbPlaywright helper mixin is included below for its wrappers around the
 * Playwright Java option objects (launchBrowser(), navigate()). Its lifecycle
 * functions beforeAll()/afterAll() are NOT used: they call super.beforeAll() /
 * super.afterAll() and swallow the resulting "method not found" error by
 * matching Lucee's and Adobe's message wording only, so on BoxLang (different
 * wording) they rethrow and every fetch fails. This backend does its own driver
 * init (initPlaywright) and close (shutdown) instead, replicating the mixin's
 * driver resolution and version check without the super calls. This backend
 * adds the crawl-specific parts: a configurable wait for JavaScript, the
 * result-struct shape, and robots.txt fetching. Using the mixin needs a
 * "/cbPlaywright" mapping and the Playwright jars on the class path; the host
 * Application.cfc sets both (see the test-harness Application.cfc).
 *
 * Lifecycle: the Playwright instance, one browser, one context, and one page are
 * created lazily on the first fetch and reused for the whole crawl (each fetch
 * navigates the same page). The Crawler calls shutdown() when the crawl finishes
 * to close the browser and stop the driver process.
 *
 * Process cleanup: a normal crawl reaps the browser and its driver process in
 * crawl()'s finally via shutdown(). A hard JVM kill (kill -9, and most Windows
 * `box server stop`) can still leave orphaned Chromium `headless_shell`
 * processes behind. No JVM shutdown hook is added to catch that: a shutdown hook
 * does not run on those hard-kill paths, which is where the orphans actually
 * come from, so it would add cross-engine complexity for almost no coverage.
 * Playwright's own driver watches its stdin pipe and normally stops Chromium
 * when the JVM connection drops. An external process reaper is out of scope.
 * (Task 25 decision — see supportsParallel() for the parallel side.)
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
     *
     * When the navigation followed one or more HTTP redirects, the result carries
     * a "redirectChain" array of { url, status } built from Playwright's own
     * redirect history (observability only). Unlike the Jsoup backend, the browser
     * follows redirects itself, so the maxRedirects hop-limit does not apply here.
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
        var result = buildResult(
            url = page.url().toString(),
            headers = headers,
            contentType = "text/html",
            body = page.content()
        );

        var chain = buildRedirectChain( response );
        if ( chain.len() > 1 ) {
            result[ "redirectChain" ] = chain;
        }
        return result;
    }

    /**
     * Builds the { url, status } hop chain for a navigation from Playwright's
     * redirect history. Walks request.redirectedFrom() back to the first request,
     * then emits the hops in first-to-last order. Returns an empty array when the
     * response is null (an in-page navigation with no main response).
     * @response The main navigation Response, or null.
     */
    private array function buildRedirectChain( any response ) {
        if ( isNull( arguments.response ) ) {
            return [];
        }
        // Collect requests newest-first: redirectedFrom() links a request to the
        // one that redirected to it.
        var reqs = [];
        var req  = arguments.response.request();
        while ( !isNull( req ) ) {
            reqs.append( req );
            req = req.redirectedFrom();
        }

        // Emit oldest-first so the chain reads requested URL -> final URL. Each
        // request's own response gives that hop's status (the 3xx for a redirect,
        // the final 200 for the last).
        var chain = [];
        for ( var i = reqs.len(); i >= 1; i-- ) {
            var hopResponse = reqs[ i ].response();
            var status      = isNull( hopResponse ) ? 0 : hopResponse.status();
            chain.append( { "url" : reqs[ i ].url(), "status" : status } );
        }
        return chain;
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
     * Reports that this backend is not safe for parallel crawling, so the Crawler
     * downgrades a runAsync crawl to single-threaded when the backend is this one.
     *
     * The reason is a hard Playwright Java rule, not just the shared page/context
     * in getPage: a Playwright instance and everything it creates (Browser,
     * BrowserContext, Page) is pinned to the one thread that created it and cannot
     * be driven from any other thread. So a per-worker context/page pool on one
     * shared instance is impossible. The only design that would actually run in
     * parallel is thread-local: each worker thread builds its OWN full stack —
     * Playwright instance, Node driver process, Browser, and Chromium
     * headless_shell. At the default asyncMaxThreads = 10 that is up to 10 headless
     * Chrome plus 10 driver processes, each ~1-2 s to start.
     *
     * That was deliberately left out (task 25, closed won't-do): the Playwright
     * backend is used for JS-heavy sites, and those crawls are usually small (a
     * handful of pages), so the process cost far outweighs the wall-clock gain.
     * Revisit only for a genuinely large JS-rendered crawl, and cap the worker
     * count well below asyncMaxThreads if so.
     */
    boolean function supportsParallel() {
        return false;
    }

    /**
     * Returns the shared page, creating the Playwright instance, a headless
     * browser, a context, and one page on first use. All are reused for the whole
     * crawl; each fetch navigates the same page.
     *
     * initPlaywright() throws a clear error when the driver is missing or its
     * version does not match cbPlaywright, which is the "optional dependency not
     * installed" signal. launchBrowser() is a cbPlaywright mixin helper.
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
     * Creates the Playwright driver instance (variables.playwright).
     *
     * This replicates the driver setup from cbPlaywright's mixin beforeAll()
     * WITHOUT its super.beforeAll() call. The mixin swallows the "method not
     * found" error from that super call by matching Lucee's and Adobe's message
     * wording; BoxLang's wording is not matched, so the mixin's beforeAll()
     * rethrows there and the backend cannot start. Until that is fixed upstream,
     * this method does the same work directly: resolve the driver directory
     * (CBPLAYWRIGHT_DRIVER_DIR, or the commandbox-cbplaywright default), check
     * the driver version against cbPlaywright's playwright.version file, point
     * the playwright.cli.dir system property at the driver, and create the
     * Playwright instance. Throws when the driver is missing or its version does
     * not match what cbPlaywright expects.
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
     * Waits for the page after navigation so JavaScript can finish.
     * @page A com.microsoft.playwright.Page
     *
     * Three stages, each skipped when unconfigured:
     * 1. Waits for the configured load state (settings.waitStrategy, "load" or
     *    "networkidle"). The mixin's own waitForLoadState() only supports "load",
     *    so this calls the Playwright API directly to allow "networkidle".
     * 2. Waits for settings.waitForSelector to appear, when set. This is the
     *    targeted alternative to a large blanket waitMs: it returns as soon as the
     *    known element exists instead of always sleeping. The wait is bounded by
     *    requestTimeout; if the selector never appears the timeout error is caught,
     *    logged, and the fetch continues (the page may simply not have it).
     * 3. Sleeps settings.waitMs, when > 0. Still supported and combinable with the
     *    selector wait; needed for content injected by a setTimeout with no network
     *    activity when you cannot name a selector.
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
