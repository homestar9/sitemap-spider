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
 * Local run recipe (validated on Adobe 2023; see the task 09 note about a
 * pre-existing Lucee 6 Crawler failure that blocks the whole suite there):
 *   1. box install cbPlaywright  (in test-harness; also installs the driver)
 *   2. box server start serverConfigFile=server-adobe@2023.json
 *   3. box testbox run runner="http://localhost:61002/tests/runner.cfm" bundles="tests.specs.PlaywrightSpec"
 */
component extends="coldbox.system.testing.BaseTestCase" appMapping="root" {

    variables.serverRoot = "http#( CGI.HTTPS == "on" ? 's' : '' )#://" & CGI.HTTP_HOST & "/";
    variables.appRoot    = variables.serverRoot & "tests/resources/sample-site/";

    // Decide skip vs run at construction, before run() registers the specs. The
    // it() skip argument is evaluated during registration, which happens before
    // beforeAll, so this cannot be set in beforeAll. The check only needs the JVM,
    // the file system, and the server scope, so it is safe here.
    //
    // Playwright is skipped when its driver is missing OR the engine is BoxLang.
    // The Playwright backend pulls in the cbPlaywright helpers with a CFML include
    // (models/browsers/Playwright.cfc), and BoxLang does not expose functions
    // defined in an included template as callable methods, so the backend's first
    // call (beforeAll) fails with "Method 'beforeAll' not found". Until cbPlaywright
    // supports BoxLang, treat BoxLang as an engine that cannot run Playwright and
    // skip these specs there, the same way a missing driver skips them. See the
    // task 15 follow-up note in plans/00-overview.md.
    variables.playwrightAvailable = driverIsInstalled() && !isBoxLang();

    function beforeAll(){
        super.beforeAll();
        setup();

        // Launching a browser is slow, so crawl once per seed here and let the
        // specs below assert on the shared results. Skip the crawls entirely when
        // the driver is missing so the specs can report as skipped, not errored.
        if ( variables.playwrightAvailable ) {
            variables.rootPages     = runCrawl( variables.appRoot ).pages;
            variables.redirectPages = runCrawl( variables.appRoot & "js-redirect-old.cfm" ).pages;
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
     */
    private struct function runCrawl( required string seedUrl ){
        var s     = getInstance( "coldbox:moduleSettings:sitemap-spider" );
        var saved = { browserDsl : s.browserDsl, waitMs : s.waitMs, maxCrawlDelay : s.maxCrawlDelay, maxDepth : s.maxDepth };

        s.browserDsl    = "Playwright@sitemap-spider";
        s.waitMs        = 3500;
        s.maxCrawlDelay = 0;
        s.maxDepth      = 1;

        try {
            return getInstance( "Crawler@sitemap-spider" ).crawl( [ arguments.seedUrl ], [] );
        } finally {
            s.browserDsl    = saved.browserDsl;
            s.waitMs        = saved.waitMs;
            s.maxCrawlDelay = saved.maxCrawlDelay;
            s.maxDepth      = saved.maxDepth;
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

    /**
     * Returns true when the CFML engine is BoxLang. BoxLang populates a "boxlang"
     * key in the server scope (its ColdFusion-compat shim otherwise reports the
     * product name as "Lucee", so that name cannot be used to tell them apart).
     * Used to skip the Playwright specs, since the cbPlaywright include-based
     * mixin does not load on BoxLang.
     */
    private boolean function isBoxLang(){
        return server.keyExists( "boxlang" );
    }

}
