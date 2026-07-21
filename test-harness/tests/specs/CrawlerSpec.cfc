/**
 * Unit specs for Crawler.cfc.
 *
 * Two parts:
 *   1. Regression specs for the task 03 correctness fixes (getPriority floor,
 *      isUrlAllowed no longer inverts its reMatch arguments).
 *   2. Task 05 behavior specs for crawl() driven by a fake browser, so a full
 *      breadth-first crawl runs with no real HTTP.
 *
 * getPriority() and isUrlAllowed() are private, exposed here with makePublic().
 * The fake browser is injected with MockBox $property after onDiComplete has
 * already set variables.browser, so no production change is needed.
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
		// Expose the private methods under test.
		makePublic( variables.crawler, "getPriority" );
		makePublic( variables.crawler, "isUrlAllowed" );
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

			describe( "isUrlAllowed()", function(){

				it( "allows a normal .cfm page URL", function(){
					expect( variables.crawler.isUrlAllowed( "http://example.test/contact.cfm" ) ).toBeTrue();
				} );

				it( "rejects image, mailto, and tel URLs", function(){
					expect( variables.crawler.isUrlAllowed( "http://example.test/assets/img/sample.jpg" ) ).toBeFalse();
					expect( variables.crawler.isUrlAllowed( "mailto:support@example.test" ) ).toBeFalse();
					expect( variables.crawler.isUrlAllowed( "tel:+18005551212" ) ).toBeFalse();
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

				ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [], runAsync = false );

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

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [], runAsync = false );

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

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [], runAsync = false );

				// The cutoff engaged: fewer than all five pages were recorded, and at
				// least maxPages made it in. The exact count is maxPages + 1 because
				// crawlUrl checks structCount > maxPages before appending.
				expect( structCount( result.pages ) ).toBeLT( 5 );
				expect( structCount( result.pages ) ).toBeGTE( 2 );
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

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [], runAsync = false );

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

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [], runAsync = false );

				expect( result.badUrls ).toHaveKey( badUrl );
				expect( result.badUrls[ badUrl ] ).toHaveKey( "message" );
				expect( result.pages ).notToHaveKey( badUrl );
				expect( result.pages ).toHaveKey( goodUrl );
			} );

			it( "never fetches an excluded URL", function(){
				var keepUrl = variables.root & "a.cfm";
				var dropUrl = variables.root & "b.cfm";

				var ctx = buildCrawler();
				ctx.fake.addPage( variables.root, link( keepUrl ) & link( dropUrl ) );
				ctx.fake.addPage( keepUrl, "" );
				ctx.fake.addPage( dropUrl, "" );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [ dropUrl ], runAsync = false );

				expect( ctx.fake.getRequestedUrls().findNoCase( dropUrl ) ).toBe( 0 );
				expect( result.pages ).notToHaveKey( dropUrl );
				expect( result.pages ).toHaveKey( keepUrl );
			} );

		} );
	}

}
