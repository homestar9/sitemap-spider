/**
 * Unit specs for Crawler.cfc.
 *
 * Two parts:
 *   1. Regression spec for the task 03 getPriority floor fix.
 *   2. Task 05 behavior specs for crawl() driven by a fake browser, so a full
 *      breadth-first crawl runs with no real HTTP.
 *
 * The URL-allowance rule moved to Parser in task 06 (Crawler now delegates to
 * parser.isUrlAllowed), so its regression coverage lives in ParserSpec.
 *
 * getPriority() is private, exposed here with makePublic(). The fake browser is
 * injected with MockBox $property after onDiComplete has already set
 * variables.browser, so no production change is needed.
 *
 * Local run recipe:
 *   1. box server start serverConfigFile=server-adobe@2023.json
 *   2. box testbox run runner="http://localhost:61002/tests/runner.cfm" bundles="tests.specs.CrawlerSpec"
 */
component extends="coldbox.system.testing.BaseTestCase" appMapping="root" {

	// Base URL of the fake site every crawl() spec starts from.
	variables.root = "http://example.test/";

	function beforeAll(){
		super.beforeAll();
		setup();

		variables.crawler = getInstance( "Crawler@sitemap-spider" );
		// Expose the private method under test.
		makePublic( variables.crawler, "getPriority" );
	}

	function afterAll(){
		super.afterAll();
	}

	/**
	 * Builds a fresh Crawler wired to a fresh FakeBrowser. crawl() mutates
	 * instance state, so every scenario needs its own crawler.
	 *
	 * @settingOverrides Keys to override on a copy of the module settings
	 *                   (e.g. { maxDepth: 1 }). The real settings struct is left
	 *                   untouched so scenarios stay isolated.
	 */
	private struct function buildCrawler( struct settingOverrides = {} ){
		var fake    = new tests.resources.FakeBrowser();
		var crawler = prepareMock( getInstance( "Crawler@sitemap-spider" ) );
		crawler.$property( propertyName = "browser", mock = fake );

		if ( !structIsEmpty( arguments.settingOverrides ) ) {
			var s = duplicate( getInstance( "coldbox:moduleSettings:sitemap-spider" ) );
			for ( var key in arguments.settingOverrides ) {
				s[ key ] = arguments.settingOverrides[ key ];
			}
			crawler.$property( propertyName = "settings", mock = s );
		}

		return { crawler : crawler, fake : fake };
	}

	// Builds an <a href> tag with an absolute href (relative hrefs would not
	// resolve, since the Parser parses page html with no base URI).
	private string function link( required string url ){
		return '<a href="#arguments.url#">#arguments.url#</a>';
	}

	// Wires a fan-out graph on the fake browser: root links to every url in the
	// list, and every page links back to the first url. The first url is therefore
	// discovered from many pages at once, which stresses the parallel crawler's
	// atomic claim (it must be recorded exactly once, not once per discovery).
	private void function wireGraph( required any fake, required array urls ){
		var body = "";
		for ( var u in arguments.urls ){
			body &= link( u );
		}
		arguments.fake.addPage( variables.root, body );
		for ( var u in arguments.urls ){
			arguments.fake.addPage( u, link( arguments.urls[ 1 ] ) );
		}
	}

	function run(){
		describe( "Crawler correctness fixes", function(){

			describe( "getPriority()", function(){

				it( "returns full priority at depth 0", function(){
					expect( variables.crawler.getPriority( 0 ) ).toBe( 1.0 );
				} );

				it( "floors deep priority at 0.1 instead of reaching 0.0 or negative", function(){
					// depth 20 * 0.1 decrement drops 2.0 below the 1.0 base priority,
					// so without the clamp this would be -1.0.
					expect( variables.crawler.getPriority( 20 ) ).toBe( 0.1 );
				} );

			} );

		} );

		describe( "crawl() with a fake browser", function(){

			it( "visits URLs breadth-first", function(){
				var aUrl = variables.root & "a.cfm";
				var bUrl = variables.root & "b.cfm";
				var cUrl = variables.root & "c.cfm";

				var ctx = buildCrawler();
				// root -> a, b (depth 1); a -> c (depth 2).
				ctx.fake.addPage( variables.root, link( aUrl ) & link( bUrl ) );
				ctx.fake.addPage( aUrl, link( cUrl ) );
				ctx.fake.addPage( bUrl, "" );
				ctx.fake.addPage( cUrl, "" );

				ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );

				var order = ctx.fake.getRequestedUrls();
				expect( order.len() ).toBe( 4 );
				expect( order[ 1 ] ).toBe( variables.root );
				// c is one level deeper than b, so a breadth-first crawl fetches it
				// after b. A depth-first crawl would fetch c right after a (before b).
				expect( order.findNoCase( cUrl ) ).toBeGT( order.findNoCase( bUrl ) );
			} );

			it( "stops descending past maxDepth", function(){
				var aUrl = variables.root & "a.cfm";
				var bUrl = variables.root & "b.cfm";

				var ctx = buildCrawler( { maxDepth : 1 } );
				// root (0) -> a (1) -> b (2). b sits past maxDepth = 1.
				ctx.fake.addPage( variables.root, link( aUrl ) );
				ctx.fake.addPage( aUrl, link( bUrl ) );
				ctx.fake.addPage( bUrl, "" );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );

				expect( result.pages ).toHaveKey( variables.root );
				expect( result.pages ).toHaveKey( aUrl );
				expect( result.pages ).notToHaveKey( bUrl );
				// b is never even fetched: the depth check returns before the fetch.
				expect( ctx.fake.getRequestedUrls().findNoCase( bUrl ) ).toBe( 0 );
			} );

			it( "stops adding pages past maxPages", function(){
				var linked = [ "a.cfm", "b.cfm", "c.cfm", "d.cfm" ].map( ( f ) => variables.root & f );

				var ctx = buildCrawler( { maxPages : 2 } );
				// root links to four pages; with maxPages = 2 the crawl cannot record
				// all five (root + four).
				var body = "";
				for ( var u in linked ) {
					body &= link( u );
					ctx.fake.addPage( u, "" );
				}
				ctx.fake.addPage( variables.root, body );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );

				// The cutoff engaged: exactly maxPages pages were recorded, not all
				// five (root + four). Task 06 made the bound exact: crawlUrl checks
				// structCount >= maxPages before appending, so the count is maxPages.
				expect( structCount( result.pages ) ).toBe( 2 );
			} );

			it( "records a page under its canonical URL, not the fetched URL", function(){
				var aboutIndex = variables.root & "about/index.cfm";
				var aboutCanonical = variables.root & "about/";

				var ctx = buildCrawler();
				ctx.fake.addPage( variables.root, link( aboutIndex ) );
				// The about page declares its canonical as about/ (no index.cfm).
				ctx.fake.addPage(
					aboutIndex,
					'<html><head><link rel="canonical" href="#aboutCanonical#"></head><body></body></html>'
				);

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );

				expect( result.pages ).toHaveKey( aboutCanonical );
				expect( result.pages ).notToHaveKey( aboutIndex );
				// root + about/ only; the fetched about/index.cfm is not a second entry.
				expect( structCount( result.pages ) ).toBe( 2 );
			} );

			it( "records a fetch failure in badUrls and skips the page", function(){
				var goodUrl = variables.root & "a.cfm";
				var badUrl  = variables.root & "b.cfm";

				var ctx = buildCrawler();
				ctx.fake.addPage( variables.root, link( goodUrl ) & link( badUrl ) );
				ctx.fake.addPage( goodUrl, "" );
				ctx.fake.failOn( badUrl, "boom" );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );

				expect( result.badUrls ).toHaveKey( badUrl );
				expect( result.badUrls[ badUrl ] ).toHaveKey( "message" );
				expect( result.pages ).notToHaveKey( badUrl );
				expect( result.pages ).toHaveKey( goodUrl );
			} );

			it( "follows a meta-refresh and records the target, not the interstitial", function(){
				var oldUrl = variables.root & "redirect-old.cfm";
				var newUrl = variables.root & "redirect-new.cfm";

				var ctx = buildCrawler();
				ctx.fake.addPage( variables.root, link( oldUrl ) );
				// The interstitial carries a meta-refresh to the new URL (absolute so
				// getMetaRefreshUrl resolves it without a parse base).
				ctx.fake.addPage(
					oldUrl,
					'<html><head><meta http-equiv="refresh" content="3;url=#newUrl#"></head><body></body></html>'
				);
				ctx.fake.addPage( newUrl, "" );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );

				expect( result.pages ).toHaveKey( newUrl );
				expect( result.pages ).notToHaveKey( oldUrl );
			} );

			it( "records the final URL of an HTTP redirect, not the requested URL", function(){
				var oldUrl = variables.root & "location-old.cfm";
				var newUrl = variables.root & "location-new.cfm";

				var ctx = buildCrawler();
				ctx.fake.addPage( variables.root, link( oldUrl ) );
				// finalUrl simulates jsoup following a 30x: the fetch of oldUrl returns
				// a result whose url key is newUrl.
				ctx.fake.addPage( oldUrl, "", {}, newUrl );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );

				expect( result.pages ).toHaveKey( newUrl );
				expect( result.pages ).notToHaveKey( oldUrl );
				// newUrl is recorded via the redirect from oldUrl; it is never fetched
				// on its own, so the browser sees only root + oldUrl.
				expect( ctx.fake.getRequestedUrls().findNoCase( newUrl ) ).toBe( 0 );
			} );

			it( "never fetches an excluded URL", function(){
				var keepUrl = variables.root & "a.cfm";
				var dropUrl = variables.root & "b.cfm";

				var ctx = buildCrawler();
				ctx.fake.addPage( variables.root, link( keepUrl ) & link( dropUrl ) );
				ctx.fake.addPage( keepUrl, "" );
				ctx.fake.addPage( dropUrl, "" );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [ dropUrl ] );

				expect( ctx.fake.getRequestedUrls().findNoCase( dropUrl ) ).toBe( 0 );
				expect( result.pages ).notToHaveKey( dropUrl );
				expect( result.pages ).toHaveKey( keepUrl );
			} );

		} );

		describe( "crawl() in parallel (runAsync=true)", function(){

			// Wire a wider fan-out graph than the sample site so the parallel
			// claim is exercised on many URLs discovered at once. Crawl it once
			// synchronously and once in parallel and assert the recorded page set
			// matches, regardless of the (now nondeterministic) visit order.
			it( "records the same pages as a synchronous crawl, regardless of order", function(){
				var linked = [];
				for ( var i = 1; i <= 8; i++ ){
					linked.append( variables.root & "p#i#.cfm" );
				}

				var syncCtx = buildCrawler();
				wireGraph( syncCtx.fake, linked );
				var syncResult = syncCtx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );

				var asyncCtx = buildCrawler();
				wireGraph( asyncCtx.fake, linked );
				var asyncResult = asyncCtx.crawler.crawl( urls = [ variables.root ], excludeUrls = [], runAsync = true );

				// The crawl actually ran in parallel (no Crawl-delay, parallel-safe fake).
				expect( asyncResult.runAsync ).toBeTrue();
				// root + p1..p8 = 9 pages, recorded once each despite p1 being
				// linked back to from every page.
				expect( structCount( asyncResult.pages ) ).toBe( 9 );
				expect( structKeyArray( asyncResult.pages ).sort( "textnocase" ) )
					.toBe( structKeyArray( syncResult.pages ).sort( "textnocase" ) );
				expect( asyncResult.badUrls ).toBeEmpty();
			} );

			it( "records a fetch failure in badUrls under parallel crawling", function(){
				var goodUrl = variables.root & "a.cfm";
				var badUrl  = variables.root & "b.cfm";

				var ctx = buildCrawler();
				ctx.fake.addPage( variables.root, link( goodUrl ) & link( badUrl ) );
				ctx.fake.addPage( goodUrl, "" );
				ctx.fake.failOn( badUrl, "boom" );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [], runAsync = true );

				expect( result.runAsync ).toBeTrue();
				expect( result.badUrls ).toHaveKey( badUrl );
				expect( result.pages ).toHaveKey( goodUrl );
				expect( result.pages ).notToHaveKey( badUrl );
			} );

			it( "runs synchronously when robots.txt sets a Crawl-delay, even with runAsync=true", function(){
				// maxCrawlDelay is overridden above 0 so the robots Crawl-delay is
				// actually applied (the test harness pins it to 0 otherwise).
				var ctx = buildCrawler( { maxCrawlDelay : 10 } );
				ctx.fake.setRobots( "User-agent: *" & chr( 10 ) & "Crawl-delay: 5" );
				ctx.fake.addPage( variables.root, "" );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [], runAsync = true );

				// A Crawl-delay forces single-threaded so the delay is honored
				// between fetches; parallel fetching would defeat it.
				expect( result.runAsync ).toBeFalse();
				expect( result.pages ).toHaveKey( variables.root );
			} );

		} );
	}

}
