/**
 * Tests JavaScript links, delayed content, and client-side redirects with a real
 * Playwright browser. The examples skip when the Playwright driver is not installed.
 */
component extends="coldbox.system.testing.BaseTestCase" appMapping="root" {

    variables.serverRoot = "http#( CGI.HTTPS == "on" ? 's' : '' )#://" & CGI.HTTP_HOST & "/";
    variables.appRoot    = variables.serverRoot & "tests/resources/sample-site/";

    // TestBox evaluates skip while run() registers examples, before beforeAll().
    variables.playwrightAvailable = driverIsInstalled();

    /**
     * beforeAll
     *
     * Loads the shared dependencies and fixtures for these specs.
     */
    function beforeAll(){
        super.beforeAll();
        setup();

        // Share each browser crawl because starting Playwright is slow.
        // Skip all crawls when the driver is missing.
        if ( variables.playwrightAvailable ) {
            variables.rootPages     = runCrawl( variables.appRoot ).pages;
            variables.redirectPages = runCrawl( variables.appRoot & "js-redirect-old.cfm" ).pages;
            // Find the late link with a selector instead of a fixed delay.
            variables.selectorPages = runCrawl(
                seedUrl         = variables.appRoot,
                waitMs          = 0,
                waitForSelector = "a[href='js-link-late.cfm']"
            ).pages;
        }
    }

    /**
     * afterAll
     *
     * Restores shared state changed by these specs.
     */
    function afterAll(){
        super.afterAll();
    }

    /**
     * run
     *
     * Defines the PlaywrightSpec examples.
     */
    function run(){
        describe( "Playwright browser backend", function(){

            it(
                title = "finds a link injected immediately by JavaScript (js-link.cfm)",
                skip  = !variables.playwrightAvailable,
                body  = function(){
                    expect( hasPage( variables.rootPages, variables.appRoot & "js-link.cfm" ) ).toBeTrue();
                }
            );

            it(
                title = "finds a link injected after a 3s setTimeout (js-link-late.cfm)",
                skip  = !variables.playwrightAvailable,
                body  = function(){
                    // Only reachable because runCrawl sets waitMs above 3000.
                    expect( hasPage( variables.rootPages, variables.appRoot & "js-link-late.cfm" ) ).toBeTrue();
                }
            );

            it(
                title = "finds the late link via waitForSelector with waitMs = 0",
                skip  = !variables.playwrightAvailable,
                body  = function(){
                    // The blanket waitMs is 0 here; the crawl only reaches the late
                    // link because waitForSelector waited for it to be injected.
                    expect( hasPage( variables.selectorPages, variables.appRoot & "js-link-late.cfm" ) ).toBeTrue();
                }
            );

            it(
                title = "follows a JavaScript location.replace redirect to contact.cfm",
                skip  = !variables.playwrightAvailable,
                body  = function(){
                    expect( hasPage( variables.redirectPages, variables.appRoot & "contact.cfm" ) ).toBeTrue();
                    expect( hasPage( variables.redirectPages, variables.appRoot & "js-redirect-old.cfm" ) ).toBeFalse();
                }
            );

        } );
    }

    /**
     * hasPage
     *
     * Returns whether the page array contains a URL.
     */
    private boolean function hasPage( required array pages, required string url ){
        for ( var page in arguments.pages ){
            if ( page.url == arguments.url ){
                return true;
            }
        }
        return false;
    }

    /**
     * runCrawl
     *
     * Runs one crawl from a seed URL using the Playwright backend.
     *
     * Temporarily selects Playwright, skips the robots delay, and limits depth.
     * Restores every changed setting after the crawl.
     *
     * @seedUrl The URL to start crawling from.
     * @waitMs Milliseconds to wait after navigation.
     * @waitForSelector Optional selector to wait for before reading the page.
     */
    private struct function runCrawl( required string seedUrl, numeric waitMs = 3500, string waitForSelector = "" ){
        var s     = getInstance( "coldbox:moduleSettings:sitemap-spider" );
        var saved = {
            browserDsl      : s.browserDsl,
            waitMs          : s.waitMs,
            waitForSelector : s.waitForSelector,
            maxCrawlDelay   : s.maxCrawlDelay,
            maxDepth        : s.maxDepth
        };

        s.browserDsl      = "Playwright@sitemap-spider";
        s.waitMs          = arguments.waitMs;
        s.waitForSelector = arguments.waitForSelector;
        s.maxCrawlDelay   = 0;
        s.maxDepth        = 1;

        try {
            return getInstance( "Crawler@sitemap-spider" ).crawl( [ arguments.seedUrl ], [] );
        } finally {
            s.browserDsl      = saved.browserDsl;
            s.waitMs          = saved.waitMs;
            s.waitForSelector = saved.waitForSelector;
            s.maxCrawlDelay   = saved.maxCrawlDelay;
            s.maxDepth        = saved.maxDepth;
        }
    }

    /**
     * driverIsInstalled
     *
     * Returns whether the configured or default Playwright driver exists.
     */
    private boolean function driverIsInstalled(){
        var javaSystem = createObject( "java", "java.lang.System" );
        var driverDir  = javaSystem.getEnv( "CBPLAYWRIGHT_DRIVER_DIR" );
        if ( isNull( driverDir ) ) {
            var fs    = javaSystem.getProperty( "file.separator" );
            driverDir = javaSystem.getProperty( "user.home" ) & fs & ".CommandBox" & fs & "cfml" & fs & "modules" & fs & "commandbox-cbplaywright" & fs & "driver";
        }
        return directoryExists( driverDir );
    }

}
