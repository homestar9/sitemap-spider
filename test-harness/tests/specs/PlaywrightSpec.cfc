/**
 * Integration spec for the Playwright browser backend (models/browsers/Playwright.cfc).
 *
 * It crawls the sample site with a real headless browser and asserts the three
 * JavaScript behaviors jsoup cannot see:
 *   1. js-link.cfm       - a link injected on DOMContentLoaded by app.js.
 *   2. js-link-late.cfm  - a link injected 3 seconds later by a setTimeout,
 *                          only found because waitMs is set above 3000.
 *   3. js-redirect-old.cfm - location.replace('contact.cfm') on window.onload,
 *                          so the page resolves to contact.cfm.
 *
 * The backend needs the Playwright browser driver (installed by
 * commandbox-cbplaywright) and its jars on the class path (loaded by the
 * test-harness Application.cfc). When the driver is not installed - a CI leg or
 * an engine that cannot run Playwright - every spec here skips, so the rest of
 * the suite stays green.
 *
 * Local run recipe (task 15 validated this on Adobe 2023, Lucee 5, Lucee 6,
 * and BoxLang):
 *   1. box install cbPlaywright  (in test-harness; also installs the driver)
 *   2. box server start serverConfigFile=server-adobe@2023.json
 *   3. box testbox run runner="http://localhost:61002/tests/runner.cfm" bundles="tests.specs.PlaywrightSpec"
 */
component extends="coldbox.system.testing.BaseTestCase" appMapping="root" {

    variables.serverRoot = "http#( CGI.HTTPS == "on" ? 's' : '' )#://" & CGI.HTTP_HOST & "/";
    variables.appRoot    = variables.serverRoot & "tests/resources/sample-site/";

    // Decide skip vs run at construction, before run() registers the specs. The
    // it() skip argument is evaluated during registration, which happens before
    // beforeAll, so this cannot be set in beforeAll. The check only needs the JVM
    // and the file system, so it is safe here.
    variables.playwrightAvailable = driverIsInstalled();

    function beforeAll(){
        super.beforeAll();
        setup();

        // Launching a browser is slow, so crawl once per seed here and let the
        // specs below assert on the shared results. Skip the crawls entirely when
        // the driver is missing so the specs can report as skipped, not errored.
        if ( variables.playwrightAvailable ) {
            variables.rootPages     = runCrawl( variables.appRoot ).pages;
            variables.redirectPages = runCrawl( variables.appRoot & "js-redirect-old.cfm" ).pages;
            // Same late link as rootPages, but found via a targeted waitForSelector
            // with waitMs = 0 instead of a 3.5s blanket sleep. Proves the selector
            // wait replaces the blanket wait.
            variables.selectorPages = runCrawl(
                seedUrl         = variables.appRoot,
                waitMs          = 0,
                waitForSelector = "a[href='js-link-late.cfm']"
            ).pages;
        }
    }

    function afterAll(){
        super.afterAll();
    }

    function run(){
        describe( "Playwright browser backend", function(){

            it(
                title = "finds a link injected immediately by JavaScript (js-link.cfm)",
                skip  = !variables.playwrightAvailable,
                body  = function(){
                    expect( variables.rootPages ).toHaveKey( variables.appRoot & "js-link.cfm" );
                }
            );

            it(
                title = "finds a link injected after a 3s setTimeout (js-link-late.cfm)",
                skip  = !variables.playwrightAvailable,
                body  = function(){
                    // Only reachable because runCrawl sets waitMs above 3000.
                    expect( variables.rootPages ).toHaveKey( variables.appRoot & "js-link-late.cfm" );
                }
            );

            it(
                title = "finds the late link via waitForSelector with waitMs = 0",
                skip  = !variables.playwrightAvailable,
                body  = function(){
                    // The blanket waitMs is 0 here; the crawl only reaches the late
                    // link because waitForSelector waited for it to be injected.
                    expect( variables.selectorPages ).toHaveKey( variables.appRoot & "js-link-late.cfm" );
                }
            );

            it(
                title = "follows a JavaScript location.replace redirect to contact.cfm",
                skip  = !variables.playwrightAvailable,
                body  = function(){
                    expect( variables.redirectPages ).toHaveKey( variables.appRoot & "contact.cfm" );
                    expect( variables.redirectPages ).notToHaveKey( variables.appRoot & "js-redirect-old.cfm" );
                }
            );

        } );
    }

    /*********************************** HELPERS ***********************************/

    /**
     * Runs one crawl from a seed URL using the Playwright backend.
     *
     * Switches the module settings to the Playwright backend for this crawl:
     * browserDsl selects it, waitMs = 3500 gives the delayed link and the JS
     * redirect time to run, maxCrawlDelay = 0 skips the robots delay, and
     * maxDepth = 1 keeps the crawl (and its per-page browser waits) short. The
     * original settings are restored afterward so other specs are unaffected.
     *
     * A fresh Crawler is resolved after the settings change so its onDiComplete
     * picks up the Playwright backend. The settings struct is the module's live
     * singleton, so mutating it changes what the Crawler and backend read.
     *
     * @seedUrl The URL to start crawling from.
     * @waitMs The blanket post-navigation wait (ms). Defaults to 3500 so the
     *         delayed link and JS redirect have time to run.
     * @waitForSelector A CSS selector to wait for instead of a long blanket wait.
     *         Empty (the default) disables it. When set, callers can pass
     *         waitMs = 0 and still catch a late-injected element.
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
     * Returns true when the Playwright browser driver directory exists, using the
     * same resolution the backend uses (CBPLAYWRIGHT_DRIVER_DIR or the default
     * commandbox-cbplaywright location). Used to skip the specs when Playwright is
     * not set up in this environment.
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
