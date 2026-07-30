/**
 * Tests crawl order, filtering, metadata, redirects, limits, progress, and
 * parallel crawling without real HTTP. MockBox replaces the browser with FakeBrowser.
 */
component extends="coldbox.system.testing.BaseTestCase" appMapping="root" {

	// Every fake crawl starts at this URL.
	variables.root = "http://example.test/";

	/**
	 * beforeAll
	 *
	 * Loads the shared dependencies and fixtures for these specs.
	 */
	function beforeAll(){
		super.beforeAll();
		setup();

		variables.crawler = getInstance( "Crawler@sitemap-spider" );
		// Expose the private method under test.
		makePublic( variables.crawler, "getPriority" );
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
	 * buildCrawler
	 *
	 * Builds a fresh Crawler and FakeBrowser. crawl() changes instance state, so
	 * each scenario needs its own Crawler.
	 *
	 * @settingOverrides Module setting values to replace on a private copy.
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

	/**
	 * link
	 *
	 * Returns an absolute HTML link. Fake pages have no base URI for relative URLs.
	 */
	private string function link( required string url ){
		return '<a href="#arguments.url#">#arguments.url#</a>';
	}

	/**
	 * extensionHtml
	 *
	 * Returns HTML with an image, hreflang alternate, and video.
	 */
	private string function extensionHtml(){
		return '<html><head><title>Extensions</title>'
			& '<meta name="description" content="A page with everything.">'
			& '<link rel="alternate" hreflang="es" href="https://es.example.test/">'
			& '</head><body>'
			& '<img src="http://example.test/photo.jpg">'
			& '<video src="http://example.test/clip.mp4" poster="http://example.test/poster.jpg"></video>'
			& '</body></html>';
	}

	/**
	 * wireGraph
	 *
	 * Adds a page graph where every child links to the first child. Parallel
	 * workers must claim that shared URL only once.
	 */
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

	/**
	 * pageUrls
	 *
	 * Returns the URL from each page struct.
	 */
	private array function pageUrls( required array pages ){
		var out = [];
		for ( var page in arguments.pages ){
			out.append( page.url );
		}
		return out;
	}

	/**
	 * hasPage
	 *
	 * Checks for an exact URL. compare() keeps /Page and /page distinct.
	 */
	private boolean function hasPage( required array pages, required string url ){
		for ( var page in arguments.pages ){
			if ( compare( page.url, arguments.url ) == 0 ){
				return true;
			}
		}
		return false;
	}

	/**
	 * findPage
	 *
	 * Returns the page for an exact URL, or an empty struct when missing.
	 */
	private struct function findPage( required array pages, required string url ){
		for ( var page in arguments.pages ){
			if ( compare( page.url, arguments.url ) == 0 ){
				return page;
			}
		}
		return {};
	}

	/**
	 * run
	 *
	 * Defines the CrawlerSpec examples.
	 */
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

				expect( hasPage( result.pages, variables.root ) ).toBeTrue();
				expect( hasPage( result.pages, aUrl ) ).toBeTrue();
				expect( hasPage( result.pages, bUrl ) ).toBeFalse();
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

				// The atomic page limit must stop exactly at maxPages.
				expect( result.pages.len() ).toBe( 2 );
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

				expect( hasPage( result.pages, aboutCanonical ) ).toBeTrue();
				expect( hasPage( result.pages, aboutIndex ) ).toBeFalse();
				// root + about/ only; the fetched about/index.cfm is not a second entry.
				expect( result.pages.len() ).toBe( 2 );
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
				expect( hasPage( result.pages, badUrl ) ).toBeFalse();
				expect( hasPage( result.pages, goodUrl ) ).toBeTrue();
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

				expect( hasPage( result.pages, newUrl ) ).toBeTrue();
				expect( hasPage( result.pages, oldUrl ) ).toBeFalse();
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

				expect( hasPage( result.pages, newUrl ) ).toBeTrue();
				expect( hasPage( result.pages, oldUrl ) ).toBeFalse();
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
				expect( hasPage( result.pages, dropUrl ) ).toBeFalse();
				expect( hasPage( result.pages, keepUrl ) ).toBeTrue();
			} );

			it( "reports a followed HTTP redirect in the redirects report", function(){
				var oldUrl = variables.root & "location-old.cfm";
				var newUrl = variables.root & "location-new.cfm";

				var ctx = buildCrawler();
				ctx.fake.addPage( variables.root, link( oldUrl ) );
				// The fetch of oldUrl reports a 2-hop chain ending at newUrl, the way
				// the real browsers set redirectChain after following a 30x.
				ctx.fake.addPage(
					url           = oldUrl,
					html          = "",
					finalUrl      = newUrl,
					redirectChain = [ { "url" : oldUrl, "status" : 301 }, { "url" : newUrl, "status" : 200 } ]
				);

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );

				var byFrom = {};
				for ( var entry in result.redirects ) {
					byFrom[ entry.from ] = entry;
				}
				expect( byFrom ).toHaveKey( oldUrl );
				expect( byFrom[ oldUrl ].to ).toBe( newUrl );
				expect( byFrom[ oldUrl ].chain.len() ).toBe( 2 );
				// A page that did not redirect is not in the report.
				expect( byFrom ).notToHaveKey( variables.root );
			} );

		} );

		describe( "crawl() ignored reporting and pattern excludes", function(){

				it( "reports an excluded link in ignored with reason 'excluded'", function(){
					var keepUrl = variables.root & "a.cfm";
					var dropUrl = variables.root & "b.cfm";

					var ctx = buildCrawler();
					ctx.fake.addPage( variables.root, link( keepUrl ) & link( dropUrl ) );
					ctx.fake.addPage( keepUrl, "" );
					ctx.fake.addPage( dropUrl, "" );

					var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [ dropUrl ] );

					expect( result.ignored ).toBeArray();
					var reasons = {};
					for ( var entry in result.ignored ) {
						reasons[ entry.url ] = entry.reason;
					}
					expect( reasons ).toHaveKey( dropUrl );
					expect( reasons[ dropUrl ] ).toBe( "excluded" );
				} );

				it( "skips and reports a link matching excludePattern", function(){
					var keepUrl  = variables.root & "a.cfm";
					var adminUrl = variables.root & "admin/secret.cfm";

					// excludePattern is a module setting; override it on a copy so the
					// whole /admin/ section is skipped.
					var ctx = buildCrawler( { excludePattern : "/admin/" } );
					ctx.fake.addPage( variables.root, link( keepUrl ) & link( adminUrl ) );
					ctx.fake.addPage( keepUrl, "" );
					ctx.fake.addPage( adminUrl, "" );

					var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );

					expect( ctx.fake.getRequestedUrls().findNoCase( adminUrl ) ).toBe( 0 );
					expect( hasPage( result.pages, adminUrl ) ).toBeFalse();
					expect( hasPage( result.pages, keepUrl ) ).toBeTrue();

					var reasons = {};
					for ( var entry in result.ignored ) {
						reasons[ entry.url ] = entry.reason;
					}
					expect( reasons ).toHaveKey( adminUrl );
					expect( reasons[ adminUrl ] ).toBe( "excluded" );
				} );

			} );

		describe( "crawl() in parallel (runAsync=true)", function(){

			// Compare page sets because parallel fetch order is not deterministic.
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
				expect( asyncResult.pages.len() ).toBe( 9 );
				expect( pageUrls( asyncResult.pages ).sort( "textnocase" ) )
					.toBe( pageUrls( syncResult.pages ).sort( "textnocase" ) );
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
				expect( hasPage( result.pages, goodUrl ) ).toBeTrue();
				expect( hasPage( result.pages, badUrl ) ).toBeFalse();
			} );

			it( "still runs in parallel when robots.txt sets a Crawl-delay, spacing the fetches", function(){
				// Crawl-delay spaces parallel fetches. Use a small capped delay.
				var ctx = buildCrawler( { maxCrawlDelay : 1 } );
				ctx.fake.setRobots( "User-agent: *" & chr( 10 ) & "Crawl-delay: 1" );
				var linked = [];
				for ( var i = 1; i <= 3; i++ ){
					linked.append( variables.root & "p#i#.cfm" );
				}
				wireGraph( ctx.fake, linked );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [], runAsync = true );

				expect( result.runAsync ).toBeTrue();
				// root + p1..p3 = 4 pages, all recorded despite the delay spacing.
				expect( result.pages.len() ).toBe( 4 );
			} );

			it( "never records more than maxPages under parallel crawling", function(){
				// appendPage() must enforce maxPages when workers finish together.
				var ctx = buildCrawler( { maxPages : 3 } );
				var linked = [];
				for ( var i = 1; i <= 20; i++ ){
					linked.append( variables.root & "p#i#.cfm" );
				}
				wireGraph( ctx.fake, linked );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [], runAsync = true );

				expect( result.runAsync ).toBeTrue();
				expect( result.pages.len() ).toBeLTE( 3 );
			} );

			it( "downgrades to single-threaded when the backend is not parallel-safe", function(){
				// A backend that reports supportsParallel()=false (like Playwright)
				// forces sync even when runAsync=true, and every page is still found.
				var ctx = buildCrawler();
				ctx.fake.setParallelSupported( false );
				var linked = [];
				for ( var i = 1; i <= 4; i++ ){
					linked.append( variables.root & "p#i#.cfm" );
				}
				wireGraph( ctx.fake, linked );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [], runAsync = true );

				expect( result.runAsync ).toBeFalse();
				expect( result.pages.len() ).toBe( 5 );
			} );

		} );

		// Synchronous and parallel crawls must normalize URLs the same way.
		describe( "crawl() URL normalization", function(){

			// Register only the normalized URL so an incorrect fetch throws.
			it( "dedups a URL differing only in host case (sync)", function(){
				var dupUrl = variables.root & "dup.cfm"; // http://example.test/dup.cfm

				var ctx = buildCrawler();
				ctx.fake.addPage( variables.root, link( "http://EXAMPLE.test/dup.cfm" ) & link( dupUrl ) );
				ctx.fake.addPage( dupUrl, "" );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );

				expect( hasPage( result.pages, dupUrl ) ).toBeTrue();
				// root + dup only; the uppercase-host variant is not a second entry.
				expect( result.pages.len() ).toBe( 2 );
			} );

			it( "dedups a URL differing only in host case (parallel)", function(){
				var dupUrl = variables.root & "dup.cfm";

				var ctx = buildCrawler();
				ctx.fake.addPage( variables.root, link( "http://EXAMPLE.test/dup.cfm" ) & link( dupUrl ) );
				ctx.fake.addPage( dupUrl, "" );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [], runAsync = true );

				expect( result.runAsync ).toBeTrue();
				expect( hasPage( result.pages, dupUrl ) ).toBeTrue();
				expect( result.pages.len() ).toBe( 2 );
			} );

			// A redirect whose final URL carries CFID/CFTOKEN must be recorded under
			// the clean URL, so session tokens never leak into the sitemap.
			it( "records a redirect target's clean URL, stripping session tokens (sync)", function(){
				var oldUrl   = variables.root & "old.cfm";
				var cleanNew = variables.root & "new.cfm";

				var ctx = buildCrawler();
				ctx.fake.addPage( variables.root, link( oldUrl ) );
				// The fetch of oldUrl follows a 30x to new.cfm carrying session tokens.
				ctx.fake.addPage( oldUrl, "", {}, cleanNew & "?CFID=9&CFTOKEN=8" );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );

				expect( hasPage( result.pages, cleanNew ) ).toBeTrue();
				expect( hasPage( result.pages, cleanNew & "?CFID=9&CFTOKEN=8" ) ).toBeFalse();
				expect( hasPage( result.pages, oldUrl ) ).toBeFalse();
			} );

			it( "records a redirect target's clean URL, stripping session tokens (parallel)", function(){
				var oldUrl   = variables.root & "old.cfm";
				var cleanNew = variables.root & "new.cfm";

				var ctx = buildCrawler();
				ctx.fake.addPage( variables.root, link( oldUrl ) );
				ctx.fake.addPage( oldUrl, "", {}, cleanNew & "?CFID=9&CFTOKEN=8" );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [], runAsync = true );

				expect( result.runAsync ).toBeTrue();
				expect( hasPage( result.pages, cleanNew ) ).toBeTrue();
				expect( hasPage( result.pages, cleanNew & "?CFID=9&CFTOKEN=8" ) ).toBeFalse();
				expect( hasPage( result.pages, oldUrl ) ).toBeFalse();
			} );

		} );

		// A rejected seed must appear in ignored with its reason.
		describe( "crawl() seed rejection reporting", function(){

			// Collects the ignored array into a { url : reason } struct.
			var reasonsOf = function( required array ignored ){
				var out = {};
				for ( var entry in arguments.ignored ){
					out[ entry.url ] = entry.reason;
				}
				return out;
			};

			it( "reports an excluded seed in ignored with reason 'excluded'", function(){
				var badSeed = variables.root & "private.cfm";

				var ctx = buildCrawler();
				ctx.fake.addPage( variables.root, "" );

				var result = ctx.crawler.crawl(
					urls        = [ variables.root, badSeed ],
					excludeUrls = [ badSeed ]
				);

				expect( hasPage( result.pages, badSeed ) ).toBeFalse();
				expect( ctx.fake.getRequestedUrls().findNoCase( badSeed ) ).toBe( 0 );
				expect( reasonsOf( result.ignored )[ badSeed ] ).toBe( "excluded" );
			} );

			it( "reports a robots-disallowed seed in ignored with reason 'disallowed'", function(){
				var badSeed = variables.root & "secret.cfm";

				var ctx = buildCrawler();
				ctx.fake.setRobots( "User-agent: *" & chr( 10 ) & "Disallow: /secret" );
				ctx.fake.addPage( variables.root, "" );

				var result = ctx.crawler.crawl( urls = [ variables.root, badSeed ], excludeUrls = [] );

				expect( hasPage( result.pages, badSeed ) ).toBeFalse();
				expect( reasonsOf( result.ignored )[ badSeed ] ).toBe( "disallowed" );
			} );

			it( "reports an off-host seed in ignored with reason 'notAllowed'", function(){
				var badSeed = "http://other.test/x.cfm"; // different host than urls[1]

				var ctx = buildCrawler();
				ctx.fake.addPage( variables.root, "" );

				var result = ctx.crawler.crawl( urls = [ variables.root, badSeed ], excludeUrls = [] );

				expect( hasPage( result.pages, badSeed ) ).toBeFalse();
				expect( reasonsOf( result.ignored )[ badSeed ] ).toBe( "notAllowed" );
			} );

		} );

		// The method argument overrides settings.excludePattern for one crawl.
		describe( "crawl() per-crawl excludePattern argument", function(){

			it( "overrides the module setting for a single crawl", function(){
				var keepUrl  = variables.root & "admin/keep.cfm"; // matched only by the module setting
				var dropUrl  = variables.root & "beta/drop.cfm";  // matched only by the per-call arg

				// Module setting excludes /admin/; the per-call arg replaces it with
				// /beta/, so /admin/ is now crawled and /beta/ is skipped.
				var ctx = buildCrawler( { excludePattern : "/admin/" } );
				ctx.fake.addPage( variables.root, link( keepUrl ) & link( dropUrl ) );
				ctx.fake.addPage( keepUrl, "" );
				ctx.fake.addPage( dropUrl, "" );

				var result = ctx.crawler.crawl(
					urls           = [ variables.root ],
					excludeUrls    = [],
					excludePattern = "/beta/"
				);

				// /admin/ is no longer excluded (the module setting was overridden).
				expect( hasPage( result.pages, keepUrl ) ).toBeTrue();
				// /beta/ is excluded by the per-call pattern and reported.
				expect( hasPage( result.pages, dropUrl ) ).toBeFalse();
				var reasons = {};
				for ( var entry in result.ignored ){
					reasons[ entry.url ] = entry.reason;
				}
				expect( reasons[ dropUrl ] ).toBe( "excluded" );
			} );

			it( "falls back to the module setting when empty", function(){
				var adminUrl = variables.root & "admin/secret.cfm";

				var ctx = buildCrawler( { excludePattern : "/admin/" } );
				ctx.fake.addPage( variables.root, link( adminUrl ) );
				ctx.fake.addPage( adminUrl, "" );

				// Empty excludePattern argument -> the module setting still applies.
				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [], excludePattern = "" );

				expect( hasPage( result.pages, adminUrl ) ).toBeFalse();
			} );

		} );

		// Each extension setting controls its matching page data.
		describe( "crawl() sitemap extension collection", function(){

			it( "records page alternates when includeHreflang is on", function(){
				var ctx = buildCrawler( { includeHreflang : true } );
				ctx.fake.addPage(
					variables.root,
					'<link rel="alternate" hreflang="es" href="https://es.example.test/">'
					& '<link rel="alternate" hreflang="x-default" href="http://example.test/">'
				);

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );
				var page   = findPage( result.pages, variables.root );

				expect( page.alternates.len() ).toBe( 2 );
				expect( page.alternates[ 1 ].hreflang ).toBe( "es" );
				expect( page.alternates[ 1 ].href ).toBe( "https://es.example.test/" );
				expect( page.alternates[ 2 ].hreflang ).toBe( "x-default" );
			} );

			it( "leaves alternates as an empty array when includeHreflang is off", function(){
				var ctx = buildCrawler();
				ctx.fake.addPage(
					variables.root,
					'<link rel="alternate" hreflang="es" href="https://es.example.test/">'
				);

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );
				var page   = findPage( result.pages, variables.root );

				expect( page.keyExists( "alternates" ) ).toBeTrue();
				expect( page.alternates.len() ).toBe( 0 );
			} );

			it( "records page videos when includeVideos is on", function(){
				var ctx = buildCrawler( { includeVideos : true } );
				ctx.fake.addPage(
					variables.root,
					'<html><head><title>Video Page</title>'
					& '<meta name="description" content="A page with a video.">'
					& '</head><body>'
					& '<video src="http://example.test/clip.mp4" poster="http://example.test/poster.jpg"></video>'
					& '</body></html>'
				);

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );
				var page   = findPage( result.pages, variables.root );

				expect( page.videos.len() ).toBe( 1 );
				expect( page.videos[ 1 ].contentLoc ).toBe( "http://example.test/clip.mp4" );
				expect( page.videos[ 1 ].thumbnailLoc ).toBe( "http://example.test/poster.jpg" );
				expect( page.videos[ 1 ].title ).toBe( "Video Page" );
				expect( page.videos[ 1 ].description ).toBe( "A page with a video." );
			} );

			it( "leaves videos as an empty array when includeVideos is off", function(){
				var ctx = buildCrawler();
				ctx.fake.addPage(
					variables.root,
					'<video src="http://example.test/clip.mp4" poster="http://example.test/poster.jpg"></video>'
				);

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );
				var page   = findPage( result.pages, variables.root );

				expect( page.keyExists( "videos" ) ).toBeTrue();
				expect( page.videos.len() ).toBe( 0 );
			} );

		} );

		// Method arguments override extension settings for one crawl.
		describe( "crawl() per-crawl extension flag arguments", function(){

			it( "collects images when the argument is true and the setting is off", function(){
				var ctx = buildCrawler( { includeImages : false } );
				ctx.fake.addPage( variables.root, extensionHtml() );

				var result = ctx.crawler.crawl(
					urls          = [ variables.root ],
					excludeUrls   = [],
					includeImages = true
				);

				expect( findPage( result.pages, variables.root ).images.len() ).toBe( 1 );
			} );

			it( "skips images when the argument is false and the setting is on", function(){
				var ctx = buildCrawler( { includeImages : true } );
				ctx.fake.addPage( variables.root, extensionHtml() );

				var result = ctx.crawler.crawl(
					urls          = [ variables.root ],
					excludeUrls   = [],
					includeImages = false
				);

				expect( findPage( result.pages, variables.root ).images.len() ).toBe( 0 );
			} );

			it( "collects alternates when the argument is true and the setting is off", function(){
				var ctx = buildCrawler( { includeHreflang : false } );
				ctx.fake.addPage( variables.root, extensionHtml() );

				var result = ctx.crawler.crawl(
					urls            = [ variables.root ],
					excludeUrls     = [],
					includeHreflang = true
				);

				expect( findPage( result.pages, variables.root ).alternates.len() ).toBe( 1 );
			} );

			it( "skips alternates when the argument is false and the setting is on", function(){
				var ctx = buildCrawler( { includeHreflang : true } );
				ctx.fake.addPage( variables.root, extensionHtml() );

				var result = ctx.crawler.crawl(
					urls            = [ variables.root ],
					excludeUrls     = [],
					includeHreflang = false
				);

				expect( findPage( result.pages, variables.root ).alternates.len() ).toBe( 0 );
			} );

			it( "collects videos when the argument is true and the setting is off", function(){
				var ctx = buildCrawler( { includeVideos : false } );
				ctx.fake.addPage( variables.root, extensionHtml() );

				var result = ctx.crawler.crawl(
					urls          = [ variables.root ],
					excludeUrls   = [],
					includeVideos = true
				);

				expect( findPage( result.pages, variables.root ).videos.len() ).toBe( 1 );
			} );

			it( "skips videos when the argument is false and the setting is on", function(){
				var ctx = buildCrawler( { includeVideos : true } );
				ctx.fake.addPage( variables.root, extensionHtml() );

				var result = ctx.crawler.crawl(
					urls          = [ variables.root ],
					excludeUrls   = [],
					includeVideos = false
				);

				expect( findPage( result.pages, variables.root ).videos.len() ).toBe( 0 );
			} );

			it( "falls back to the module settings when no flag argument is passed", function(){
				var ctx = buildCrawler( { includeImages : true, includeHreflang : true, includeVideos : true } );
				ctx.fake.addPage( variables.root, extensionHtml() );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );
				var page   = findPage( result.pages, variables.root );

				expect( page.images.len() ).toBe( 1 );
				expect( page.alternates.len() ).toBe( 1 );
				expect( page.videos.len() ).toBe( 1 );
			} );

		} );

		// The pages array preserves URL paths that differ only by case.
		describe( "crawl() records case-variant URLs separately", function(){

			it( "keeps /Page and /page as two pages", function(){
				var upperUrl = variables.root & "Page.cfm";
				var lowerUrl = variables.root & "page.cfm";

				var ctx = buildCrawler();
				ctx.fake.addPage( variables.root, link( upperUrl ) & link( lowerUrl ) );
				ctx.fake.addPage( upperUrl, "" );
				ctx.fake.addPage( lowerUrl, "" );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );

				// root + both case variants = 3 distinct pages.
				expect( result.pages.len() ).toBe( 3 );
				expect( hasPage( result.pages, upperUrl ) ).toBeTrue();
				expect( hasPage( result.pages, lowerUrl ) ).toBeTrue();
			} );

		} );

		// crawl() updates and checks the optional CrawlProgress argument.
		describe( "crawl() progress and cancellation", function(){

			// A fresh CrawlProgress to hand into crawl().
			/**
			 * progress
			 *
			 * Returns the CrawlProgress supplied to the crawler.
			 */
			function progress(){
				return getInstance( "CrawlProgress@sitemap-spider" );
			}

			it( "updates the progress counters during a crawl", function(){
				var aUrl = variables.root & "a.cfm";
				var bUrl = variables.root & "b.cfm";

				var ctx = buildCrawler();
				ctx.fake.addPage( variables.root, link( aUrl ) & link( bUrl ) );
				ctx.fake.addPage( aUrl, "" );
				ctx.fake.addPage( bUrl, "" );

				var p      = progress();
				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [], progress = p );
				var snap   = p.snapshot();

				// root + a + b were all fetched and recorded.
				expect( snap.pagesFound ).toBe( result.pages.len() );
				expect( snap.pagesFound ).toBe( 3 );
				expect( snap.urlsProcessed ).toBe( 3 );
				expect( snap.badUrls ).toBe( 0 );
				expect( snap.canceled ).toBeFalse();
			} );

			it( "counts a failed fetch in progress.badUrls", function(){
				var goodUrl = variables.root & "a.cfm";
				var badUrl  = variables.root & "b.cfm";

				var ctx = buildCrawler();
				ctx.fake.addPage( variables.root, link( goodUrl ) & link( badUrl ) );
				ctx.fake.addPage( goodUrl, "" );
				ctx.fake.failOn( badUrl, "boom" );

				var p = progress();
				ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [], progress = p );

				expect( p.snapshot().badUrls ).toBe( 1 );
			} );

			it( "records nothing when canceled before the crawl starts", function(){
				var aUrl = variables.root & "a.cfm";
				var bUrl = variables.root & "b.cfm";

				var ctx = buildCrawler();
				ctx.fake.addPage( variables.root, link( aUrl ) & link( bUrl ) );
				ctx.fake.addPage( aUrl, "" );
				ctx.fake.addPage( bUrl, "" );

				var p = progress();
				p.cancel();
				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [], progress = p );

				// The drain loop's cancel check fires immediately, so no URL is
				// fetched and no page is recorded.
				expect( result.pages.len() ).toBe( 0 );
				expect( ctx.fake.getRequestedUrls().len() ).toBe( 0 );
				expect( p.snapshot().pagesFound ).toBe( 0 );
			} );

			it( "runs a normal crawl with no progress argument (no-op default)", function(){
				var aUrl = variables.root & "a.cfm";

				var ctx = buildCrawler();
				ctx.fake.addPage( variables.root, link( aUrl ) );
				ctx.fake.addPage( aUrl, "" );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );
				expect( result.pages.len() ).toBe( 2 );
			} );

		} );

		// A create() call can override the module's browserDsl setting.
		describe( "crawl() per-crawl browserDsl argument", function(){

			it( "resolves the backend named for this crawl instead of the setting", function(){
				var ctx = buildCrawler();
				ctx.fake.addPage( variables.root, "" );

				// An unknown DSL proves the call replaced the injected fake.
				expect( function(){
					ctx.crawler.crawl(
						urls        = [ variables.root ],
						excludeUrls = [],
						browserDsl  = "NoSuchBrowser@sitemap-spider"
					);
				} ).toThrow();
			} );

			it( "keeps using the configured backend when the argument is empty", function(){
				var aUrl = variables.root & "a.cfm";

				var ctx = buildCrawler();
				ctx.fake.addPage( variables.root, link( aUrl ) );
				ctx.fake.addPage( aUrl, "" );

				// Empty means "leave it alone", so the injected fake still serves the
				// crawl and no real HTTP happens.
				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [], browserDsl = "" );

				expect( result.pages.len() ).toBe( 2 );
				expect( ctx.fake.getRequestedUrls().len() ).toBe( 2 );
			} );

		} );

		describe( "crawl() failure detail in badUrls", function(){

			it( "records the status code and reason for a missing page", function(){
				var badUrl = variables.root & "gone.cfm";

				var ctx = buildCrawler();
				ctx.fake.addPage( variables.root, link( badUrl ) );
				ctx.fake.failOn( badUrl, "not found", 404 );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );

				expect( result.badUrls[ badUrl ].status ).toBe( 404 );
				expect( result.badUrls[ badUrl ].reason ).toBe( "notFound" );
				expect( result.badUrls[ badUrl ].kind ).toBe( "page" );
			} );

			it( "separates a server error from a missing page", function(){
				var missingUrl = variables.root & "gone.cfm";
				var brokenUrl  = variables.root & "boom.cfm";

				var ctx = buildCrawler();
				ctx.fake.addPage( variables.root, link( missingUrl ) & link( brokenUrl ) );
				ctx.fake.failOn( missingUrl, "not found", 404 );
				ctx.fake.failOn( brokenUrl, "server exploded", 500 );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );

				expect( result.badUrls[ missingUrl ].reason ).toBe( "notFound" );
				expect( result.badUrls[ brokenUrl ].reason ).toBe( "serverError" );
			} );

			it( "reports a redirect loop as tooManyRedirects with no status", function(){
				var loopUrl = variables.root & "loop.cfm";

				var ctx = buildCrawler();
				ctx.fake.addPage( variables.root, link( loopUrl ) );
				ctx.fake.failOn(
					url     = loopUrl,
					message = "Too many redirects",
					status  = 0,
					chain   = [ { "url": loopUrl, "status": 301 } ],
					type    = "TooManyRedirectsException"
				);

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );

				expect( result.badUrls[ loopUrl ].reason ).toBe( "tooManyRedirects" );
				expect( result.badUrls[ loopUrl ].status ).toBe( 0 );
			} );

			it( "keeps the redirect steps that led to a failure", function(){
				var movedUrl = variables.root & "moved.cfm";
				var finalUrl = variables.root & "final.cfm";

				var ctx = buildCrawler();
				ctx.fake.addPage( variables.root, link( movedUrl ) );
				// Keep the redirect steps from the failed request.
				ctx.fake.failOn(
					url     = movedUrl,
					message = "not found",
					status  = 404,
					chain   = [
						{ "url": movedUrl, "status": 301 },
						{ "url": finalUrl, "status": 404 }
					]
				);

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );

				expect( result.badUrls[ movedUrl ].redirectChain.len() ).toBe( 2 );
				expect( result.badUrls[ movedUrl ].redirectChain[ 2 ].url ).toBe( finalUrl );
			} );

			it( "falls back to status 0 and reason unknown when the browser adds no detail", function(){
				var badUrl = variables.root & "b.cfm";

				var ctx = buildCrawler();
				ctx.fake.addPage( variables.root, link( badUrl ) );
				// Simulate a browser backend that omits status details.
				ctx.fake.failOn( badUrl, "boom" );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );

				expect( result.badUrls[ badUrl ].status ).toBe( 0 );
				expect( result.badUrls[ badUrl ].reason ).toBe( "unknown" );
			} );

		} );

		describe( "crawl() inbound link tracking", function(){

			it( "names the page a broken link was found on", function(){
				var aboutUrl = variables.root & "about.cfm";
				var badUrl   = variables.root & "gone.cfm";

				var ctx = buildCrawler();
				ctx.fake.addPage( variables.root, link( aboutUrl ) );
				ctx.fake.addPage( aboutUrl, link( badUrl ) );
				ctx.fake.failOn( badUrl, "not found", 404 );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );

				expect( result.badUrls[ badUrl ].foundOn ).toBe( [ aboutUrl ] );
				expect( result.badUrls[ badUrl ].foundOnTruncated ).toBeFalse();
			} );

			it( "lists every page linking to the same broken URL", function(){
				var badUrl = variables.root & "gone.cfm";
				var oneUrl = variables.root & "one.cfm";
				var twoUrl = variables.root & "two.cfm";

				var ctx = buildCrawler();
				ctx.fake.addPage( variables.root, link( oneUrl ) & link( twoUrl ) );
				ctx.fake.addPage( oneUrl, link( badUrl ) );
				ctx.fake.addPage( twoUrl, link( badUrl ) );
				ctx.fake.failOn( badUrl, "not found", 404 );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );

				var foundOn = result.badUrls[ badUrl ].foundOn;
				expect( foundOn.len() ).toBe( 2 );
				expect( foundOn ).toInclude( oneUrl );
				expect( foundOn ).toInclude( twoUrl );
			} );

			it( "caps the list at maxInboundLinks and marks it truncated", function(){
				var badUrl = variables.root & "gone.cfm";
				var oneUrl = variables.root & "one.cfm";
				var twoUrl = variables.root & "two.cfm";

				var ctx = buildCrawler( { maxInboundLinks : 1 } );
				ctx.fake.addPage( variables.root, link( oneUrl ) & link( twoUrl ) );
				ctx.fake.addPage( oneUrl, link( badUrl ) );
				ctx.fake.addPage( twoUrl, link( badUrl ) );
				ctx.fake.failOn( badUrl, "not found", 404 );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );

				expect( result.badUrls[ badUrl ].foundOn.len() ).toBe( 1 );
				expect( result.badUrls[ badUrl ].foundOnTruncated ).toBeTrue();
			} );

			it( "records no referrers when trackInboundLinks is off", function(){
				var aboutUrl = variables.root & "about.cfm";
				var badUrl   = variables.root & "gone.cfm";

				var ctx = buildCrawler( { trackInboundLinks : false } );
				ctx.fake.addPage( variables.root, link( aboutUrl ) );
				ctx.fake.addPage( aboutUrl, link( badUrl ) );
				ctx.fake.failOn( badUrl, "not found", 404 );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );

				expect( result.badUrls[ badUrl ].foundOn ).toBeEmpty();
			} );

			it( "keeps referrers for a redirected URL so its links can be updated", function(){
				var oldUrl = variables.root & "old.cfm";
				var newUrl = variables.root & "new.cfm";

				var ctx = buildCrawler();
				ctx.fake.addPage( variables.root, link( oldUrl ) );
				ctx.fake.addPage(
					url           = oldUrl,
					html          = "",
					finalUrl      = newUrl,
					redirectChain = [
						{ "url": oldUrl, "status": 301 },
						{ "url": newUrl, "status": 200 }
					]
				);

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );

				expect( result.redirects.len() ).toBe( 1 );
				expect( result.redirects[ 1 ].status ).toBe( 301 );
				expect( result.redirects[ 1 ].foundOn ).toBe( [ variables.root ] );
			} );

			it( "records the failure detail and referrer under parallel crawling", function(){
				var aboutUrl = variables.root & "about.cfm";
				var badUrl   = variables.root & "gone.cfm";

				var ctx = buildCrawler();
				ctx.fake.addPage( variables.root, link( aboutUrl ) );
				ctx.fake.addPage( aboutUrl, link( badUrl ) );
				ctx.fake.failOn( badUrl, "not found", 404 );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [], runAsync = true );

				expect( result.runAsync ).toBeTrue();
				expect( result.badUrls[ badUrl ].status ).toBe( 404 );
				expect( result.badUrls[ badUrl ].reason ).toBe( "notFound" );
				expect( result.badUrls[ badUrl ].foundOn ).toBe( [ aboutUrl ] );
			} );

		} );

		describe( "crawl() asset checking", function(){

			it( "checks nothing when checkAssets is off", function(){
				var ctx = buildCrawler();
				ctx.fake.addPage( variables.root, '<img src="#variables.root#logo.png">' );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );

				expect( ctx.fake.getCheckedUrls() ).toBeEmpty();
				expect( result.assetsChecked ).toBe( 0 );
			} );

			it( "reports a missing image as a broken asset", function(){
				var imageUrl = variables.root & "logo.png";

				var ctx = buildCrawler( { checkAssets : true } );
				ctx.fake.addPage( variables.root, '<img src="#imageUrl#">' );
				ctx.fake.addAsset( imageUrl, 404 );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );

				expect( result.badUrls ).toHaveKey( imageUrl );
				expect( result.badUrls[ imageUrl ].kind ).toBe( "asset" );
				expect( result.badUrls[ imageUrl ].status ).toBe( 404 );
				expect( result.badUrls[ imageUrl ].foundOn ).toBe( [ variables.root ] );
				// An asset is never a sitemap entry.
				expect( hasPage( result.pages, imageUrl ) ).toBeFalse();
			} );

			it( "leaves a working asset out of badUrls", function(){
				var imageUrl = variables.root & "logo.png";

				var ctx = buildCrawler( { checkAssets : true } );
				ctx.fake.addPage( variables.root, '<img src="#imageUrl#">' );
				ctx.fake.addAsset( imageUrl, 200 );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );

				expect( result.badUrls ).notToHaveKey( imageUrl );
				expect( result.assetsChecked ).toBe( 1 );
			} );

			it( "checks a stylesheet, a script, and a directly linked image", function(){
				var cssUrl   = variables.root & "site.css";
				var jsUrl    = variables.root & "site.js";
				// notAllowedPattern blocks .jpg, so only the asset check sees it.
				var photoUrl = variables.root & "photo.jpg";

				var ctx = buildCrawler( { checkAssets : true } );
				ctx.fake.addPage(
					variables.root,
					'<link rel="stylesheet" href="#cssUrl#">'
						& '<script src="#jsUrl#"></script>'
						& link( photoUrl )
				);
				ctx.fake.addAsset( cssUrl, 200 );
				ctx.fake.addAsset( jsUrl, 200 );
				ctx.fake.addAsset( photoUrl, 200 );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );

				var checked = ctx.fake.getCheckedUrls();
				expect( checked ).toInclude( cssUrl );
				expect( checked ).toInclude( jsUrl );
				expect( checked ).toInclude( photoUrl );
				expect( result.assetsChecked ).toBe( 3 );
			} );

			it( "requests an asset used by several pages only once", function(){
				var imageUrl = variables.root & "logo.png";
				var oneUrl   = variables.root & "one.cfm";
				var twoUrl   = variables.root & "two.cfm";
				var imgTag   = '<img src="#imageUrl#">';

				var ctx = buildCrawler( { checkAssets : true } );
				ctx.fake.addPage( variables.root, link( oneUrl ) & link( twoUrl ) & imgTag );
				ctx.fake.addPage( oneUrl, imgTag );
				ctx.fake.addPage( twoUrl, imgTag );
				ctx.fake.addAsset( imageUrl, 200 );

				ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );

				expect( ctx.fake.getCheckedUrls().len() ).toBe( 1 );
			} );

			it( "ignores an off-host asset", function(){
				var ctx = buildCrawler( { checkAssets : true } );
				ctx.fake.addPage( variables.root, '<img src="https://cdn.other.test/logo.png">' );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );

				expect( ctx.fake.getCheckedUrls() ).toBeEmpty();
				expect( result.assetsChecked ).toBe( 0 );
			} );

			it( "stops collecting at maxAssetChecks and still finishes the crawl", function(){
				var ctx = buildCrawler( { checkAssets : true, maxAssetChecks : 1 } );
				ctx.fake.addPage(
					variables.root,
					'<img src="#variables.root#one.png">' & '<img src="#variables.root#two.png">'
				);
				ctx.fake.addAsset( variables.root & "one.png", 200 );
				ctx.fake.addAsset( variables.root & "two.png", 200 );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [] );

				expect( ctx.fake.getCheckedUrls().len() ).toBe( 1 );
				expect( result.pages.len() ).toBe( 1 );
			} );

			it( "checks assets under parallel crawling too", function(){
				var imageUrl = variables.root & "logo.png";

				var ctx = buildCrawler( { checkAssets : true } );
				ctx.fake.addPage( variables.root, '<img src="#imageUrl#">' );
				ctx.fake.addAsset( imageUrl, 404 );

				var result = ctx.crawler.crawl( urls = [ variables.root ], excludeUrls = [], runAsync = true );

				expect( result.runAsync ).toBeTrue();
				expect( result.badUrls ).toHaveKey( imageUrl );
				expect( result.badUrls[ imageUrl ].kind ).toBe( "asset" );
				expect( result.badUrls[ imageUrl ].foundOn ).toBe( [ variables.root ] );
			} );

		} );
	}

}
