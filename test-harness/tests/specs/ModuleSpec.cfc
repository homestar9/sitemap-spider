/**
 * Tests a complete crawl and sitemap result against the sample site.
 */
component extends="coldbox.system.testing.BaseTestCase" appMapping="root" {

	variables.serverRoot = "http#( CGI.HTTPS == "on" ? 's' : '' )#://" & CGI.HTTP_HOST & "/";

	variables.testData = {
		// Pages the crawler must include, relative to appRoot.
		// about/index.cfm declares about/ as its canonical URL.
		validPages = [
			"",
			"about/",
			"contact.cfm",
			"privacy.cfm"
		],
		// Pages the crawler must omit.
		// The index marks nofollow.cfm nofollow.
		// robots.txt disallows disallow.cfm.
		ignoredPages = [
			"disallow.cfm",
			"nofollow.cfm"
		]
	};

	/**
	 * beforeAll
	 *
	 * Loads the module and shared sample-site result.
	 */

	function beforeAll(){
		super.beforeAll();
		setup();

		// Crawl the sample site once and share the result across the specs below.
		variables.appRoot = variables.serverRoot & "tests/resources/sample-site/";
		var sitemapService = getInstance( "sitemapService@sitemap-spider" );
		variables.result = sitemapService.create( variables.appRoot );
	}

	/**
	 * afterAll
	 *
	 * Restores shared state changed by these specs.
	 */
	function afterAll(){
		// Remove any sitemap file a saveToFile spec wrote.
		if ( structKeyExists( variables, "savedSitemapFile" )
			&& len( variables.savedSitemapFile )
			&& fileExists( variables.savedSitemapFile ) ) {
			fileDelete( variables.savedSitemapFile );
		}
		// Remove the directory the index-splitting spec wrote into.
		if ( structKeyExists( variables, "splitOutDir" )
			&& len( variables.splitOutDir )
			&& directoryExists( variables.splitOutDir ) ) {
			directoryDelete( variables.splitOutDir, true );
		}
		super.afterAll();
	}

	/**
	 * ignoredPairs
	 *
	 * Returns sorted URL and reason strings for order-independent comparisons.
	 */
	private array function ignoredPairs( required array ignored ){
		var pairs = [];
		for ( var entry in arguments.ignored ){
			pairs.append( entry.url & "|" & entry.reason );
		}
		return pairs.sort( "textnocase" );
	}

	/**
	 * crawlBrokenAssets
	 *
	 * Crawls the broken-assets fixture with asset checking turned on and returns
	 * the result. checkAssets is restored afterwards so the other specs still see
	 * the module default.
	 */
	private struct function crawlBrokenAssets(){
		var settings = getInstance( "coldbox:moduleSettings:sitemap-spider" );
		var saved    = settings.checkAssets;
		settings.checkAssets = true;
		try {
			return getInstance( "sitemapService@sitemap-spider" )
				.create( variables.appRoot & "broken-assets.cfm" );
		} finally {
			settings.checkAssets = saved;
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
	 * Returns whether the page array contains an exact, case-sensitive URL.
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
	 * pageFor
	 *
	 * Returns the page for a URL or throws when it is missing.
	 */
	private struct function pageFor( required array pages, required string url ){
		for ( var page in arguments.pages ){
			if ( page.url == arguments.url ){
				return page;
			}
		}
		throw( type = "TestFailure", message = "No page recorded for #arguments.url#" );
	}

	/**
	 * run
	 *
	 * Defines the ModuleSpec examples.
	 */
	function run(){
		describe( "Sitemap Tests", function(){

			it( "returns a struct with the expected top-level keys", function(){
				expect( variables.result ).toBeStruct();
				expect( variables.result ).toHaveKey( "pages,badUrls,processedUrls,ignored,duration,filePath,saved" );
				// Robots blocks appear in ignored.
				expect( variables.result ).notToHaveKey( "disallowedUrls" );
			} );

			it( "does not save a file when no filePath is given", function(){
				// The shared baseline crawl passed no filePath, so saved is false.
				expect( variables.result.saved ).toBeFalse();
				expect( variables.result.filePath ).toBe( "" );
			} );

			it( "includes the reachable valid pages", function(){
				for ( var page in variables.testData.validPages ) {
					expect( hasPage( variables.result.pages, variables.appRoot & page ) ).toBeTrue();
				}
			} );

			it( "excludes nofollow and unreferenced pages", function(){
				for ( var page in variables.testData.ignoredPages ) {
					expect( hasPage( variables.result.pages, variables.appRoot & page ) ).toBeFalse();
				}
			} );

			it( "reports dropped links in ignored with their reasons", function(){
				// Parser and robots.txt rejections include their exact reasons.
				expect( variables.result.ignored ).toBeArray();
				var reasons = {};
				for ( var entry in variables.result.ignored ) {
					reasons[ entry.url ] = entry.reason;
				}
				expect( reasons ).toHaveKey( variables.appRoot & "nofollow.cfm" );
				expect( reasons[ variables.appRoot & "nofollow.cfm" ] ).toBe( "nofollow" );
				expect( reasons ).toHaveKey( variables.appRoot & "disallow.cfm" );
				expect( reasons[ variables.appRoot & "disallow.cfm" ] ).toBe( "disallowed" );
			} );

			it( "records unreachable links as bad URLs", function(){
				// index.cfm links to a page that returns 500, so it lands in badUrls.
				expect( variables.result.badUrls ).toBeStruct();
				expect( variables.result.badUrls ).toHaveKey( variables.appRoot & "missing.cfm" );
				// Each bad URL entry carries a "message" describing the failure.
				for ( var badUrl in variables.result.badUrls ) {
					expect( variables.result.badUrls[ badUrl ] ).toHaveKey( "message" );
				}
			} );

			it( "records the real status code and reason for a failed page", function(){
				var missingUrl = variables.appRoot & "missing.cfm";

				// The engine handles every request under this mapping, so a file that
				// is missing from disk returns 500 rather than 404.
				expect( variables.result.badUrls[ missingUrl ].status ).toBe( 500 );
				expect( variables.result.badUrls[ missingUrl ].reason ).toBe( "serverError" );
				expect( variables.result.badUrls[ missingUrl ].kind ).toBe( "page" );
			} );

			it( "names the page the broken link was found on", function(){
				var missingUrl = variables.appRoot & "missing.cfm";

				// index.cfm is the only page linking to missing.cfm.
				expect( variables.result.badUrls[ missingUrl ].foundOn ).toBe( [ variables.appRoot ] );
			} );

		} );

		describe( "asset checking against the sample site", function(){

			// broken-assets.cfm is not linked from any reachable page, so seeding it
			// directly leaves the shared baseline crawl in beforeAll untouched.

			it( "reports a missing image, stylesheet, and script as broken assets", function(){
				var result = crawlBrokenAssets();

				expect( result.badUrls ).toHaveKey( variables.appRoot & "assets/img/missing.png" );
				expect( result.badUrls ).toHaveKey( variables.appRoot & "assets/css/missing.css" );
				expect( result.badUrls ).toHaveKey( variables.appRoot & "assets/js/missing.js" );

				var missingImage = result.badUrls[ variables.appRoot & "assets/img/missing.png" ];
				expect( missingImage.kind ).toBe( "asset" );
				// A file missing from disk returns 500 here, not 404.
				expect( missingImage.status ).toBe( 500 );
				expect( missingImage.reason ).toBe( "serverError" );
				expect( missingImage.foundOn ).toBe( [ variables.appRoot & "broken-assets.cfm" ] );
			} );

			it( "reports an asset that returns a real 404 as notFound", function(){
				var result = crawlBrokenAssets();

				var goneImage = result.badUrls[ variables.appRoot & "gone-image.cfm" ];
				expect( goneImage.kind ).toBe( "asset" );
				expect( goneImage.status ).toBe( 404 );
				expect( goneImage.reason ).toBe( "notFound" );
			} );

			it( "reports a page that returns a real 404 as notFound", function(){
				var result = crawlBrokenAssets();

				var gonePage = result.badUrls[ variables.appRoot & "gone.cfm" ];
				expect( gonePage.kind ).toBe( "page" );
				expect( gonePage.status ).toBe( 404 );
				expect( gonePage.reason ).toBe( "notFound" );
				expect( gonePage.foundOn ).toBe( [ variables.appRoot & "broken-assets.cfm" ] );
			} );

			it( "reports a directly linked missing image the crawler would never fetch", function(){
				var result = crawlBrokenAssets();

				// notAllowedPattern blocks .jpg, so this link is not crawled as a page.
				expect( result.badUrls ).toHaveKey( variables.appRoot & "assets/img/gone.jpg" );
				expect( result.badUrls[ variables.appRoot & "assets/img/gone.jpg" ].kind ).toBe( "asset" );
			} );

			it( "leaves working and off-host assets out of badUrls", function(){
				var result = crawlBrokenAssets();

				// This image exists.
				expect( result.badUrls ).notToHaveKey( variables.appRoot & "assets/img/sample.jpg" );
				// The layout loads Bootstrap from a CDN, which is out of scope.
				for ( var badUrl in result.badUrls ) {
					expect( badUrl ).notToInclude( "cdn.jsdelivr.net" );
				}
			} );

			it( "keeps assets out of the sitemap and counts them separately", function(){
				var result = crawlBrokenAssets();

				expect( hasPage( result.pages, variables.appRoot & "assets/img/sample.jpg" ) ).toBeFalse();
				expect( result.stats.assetsCheckedCount ).toBeGT( 0 );
				// missing.png, missing.css, missing.js, gone.jpg, gone-image.cfm
				expect( result.stats.assetsBrokenCount ).toBeGTE( 5 );
			} );

			it( "checks no assets when checkAssets is off", function(){
				var result = getInstance( "sitemapService@sitemap-spider" )
					.create( variables.appRoot & "broken-assets.cfm" );

				expect( result.stats.assetsCheckedCount ).toBe( 0 );
				expect( result.stats.assetsBrokenCount ).toBe( 0 );
			} );

		} );

		describe( "redirect handling", function(){

			// The redirect fixtures are not linked from any reachable page, so each
			// spec seeds the interstitial URL directly. This also leaves the shared
			// baseline crawl in beforeAll untouched.

			it( "follows a meta-refresh and records the target, not the interstitial", function(){
				var oldUrl = variables.appRoot & "redirect-old.cfm";
				var newUrl = variables.appRoot & "redirect-new.cfm";

				var result = getInstance( "sitemapService@sitemap-spider" ).create( oldUrl );

				expect( hasPage( result.pages, newUrl ) ).toBeTrue();
				expect( hasPage( result.pages, oldUrl ) ).toBeFalse();
			} );

			it( "records the final URL of an HTTP (cflocation) redirect", function(){
				var oldUrl = variables.appRoot & "location-old.cfm";
				var newUrl = variables.appRoot & "location-new.cfm";

				var result = getInstance( "sitemapService@sitemap-spider" ).create( oldUrl );

				expect( hasPage( result.pages, newUrl ) ).toBeTrue();
				expect( hasPage( result.pages, oldUrl ) ).toBeFalse();
			} );

			it( "reports the HTTP redirect chain in result.redirects", function(){
				var oldUrl = variables.appRoot & "location-old.cfm";
				var newUrl = variables.appRoot & "location-new.cfm";

				var result = getInstance( "sitemapService@sitemap-spider" ).create( oldUrl );

				var byFrom = {};
				for ( var entry in result.redirects ) {
					byFrom[ entry.from ] = entry;
				}
				expect( byFrom ).toHaveKey( oldUrl );
				expect( byFrom[ oldUrl ].to ).toBe( newUrl );
				// The chain starts at the requested URL and ends at the final URL.
				expect( byFrom[ oldUrl ].chain[ 1 ].url ).toBe( oldUrl );
				expect( byFrom[ oldUrl ].chain[ byFrom[ oldUrl ].chain.len() ].url ).toBe( newUrl );
			} );

			it( "stops a redirect loop at maxRedirects and records it as bad", function(){
				var loopUrl = variables.appRoot & "redirect-loop.cfm";
				var settings = getInstance( "coldbox:moduleSettings:sitemap-spider" );
				var savedMax = settings.maxRedirects;
				// Keep the hop-limit low so the test is fast; the fixture redirects to
				// itself, so without a limit the fetch would never return.
				settings.maxRedirects = 3;
				try {
					var result = getInstance( "sitemapService@sitemap-spider" ).create( loopUrl );
					expect( result.badUrls ).toHaveKey( loopUrl );
					expect( hasPage( result.pages, loopUrl ) ).toBeFalse();
				} finally {
					settings.maxRedirects = savedMax;
				}
			} );

			it( "does not carry pages over from a previous crawl", function(){
				// WireBox can reuse Crawler, so crawl() must clear the first result.
				var service = getInstance( "sitemapService@sitemap-spider" );
				service.create( variables.appRoot & "redirect-old.cfm" );
				var second = service.create( variables.appRoot & "location-old.cfm" );

				expect( hasPage( second.pages, variables.appRoot & "location-new.cfm" ) ).toBeTrue();
				expect( hasPage( second.pages, variables.appRoot & "redirect-new.cfm" ) ).toBeFalse();
			} );

			// The JavaScript-redirect case (js-redirect-old.cfm does a
			// location.replace to contact.cfm) is not testable under the default jsoup
			// backend, which cannot run JavaScript. Its live assertion runs in
			// PlaywrightSpec, which uses the Playwright backend.

		} );

		describe( "noindex handling", function(){

			// The noindex fixtures are not linked from any reachable page, so each
			// spec starts the crawl at the fixture directly. This leaves the shared
			// baseline crawl in beforeAll untouched.

			it( "excludes a meta-noindex page but still follows its links", function(){
				var noindexUrl = variables.appRoot & "noindex.cfm";
				var childUrl   = variables.appRoot & "noindex-child.cfm";

				var result = getInstance( "sitemapService@sitemap-spider" ).create( noindexUrl );

				// The page itself stays off the sitemap and is reported in ignored,
				// but its child link (linked from nowhere else) was still crawled —
				// noindex is not nofollow.
				expect( hasPage( result.pages, noindexUrl ) ).toBeFalse();
				expect( hasPage( result.pages, childUrl ) ).toBeTrue();

				var reasons = {};
				for ( var entry in result.ignored ) {
					reasons[ entry.url ] = entry.reason;
				}
				expect( reasons ).toHaveKey( noindexUrl );
				expect( reasons[ noindexUrl ] ).toBe( "noindex" );
			} );

			it( "excludes a page served with an X-Robots-Tag noindex header", function(){
				var xrobotsUrl = variables.appRoot & "xrobots.cfm";

				var result = getInstance( "sitemapService@sitemap-spider" ).create( xrobotsUrl );

				expect( hasPage( result.pages, xrobotsUrl ) ).toBeFalse();

				var reasons = {};
				for ( var entry in result.ignored ) {
					reasons[ entry.url ] = entry.reason;
				}
				expect( reasons ).toHaveKey( xrobotsUrl );
				expect( reasons[ xrobotsUrl ] ).toBe( "noindex" );
			} );

			it( "lists noindex pages when respectNoIndex is off", function(){
				var noindexUrl = variables.appRoot & "noindex.cfm";
				var settings   = getInstance( "coldbox:moduleSettings:sitemap-spider" );
				var savedFlag  = settings.respectNoIndex;
				settings.respectNoIndex = false;
				try {
					var result = getInstance( "sitemapService@sitemap-spider" ).create( noindexUrl );
					expect( hasPage( result.pages, noindexUrl ) ).toBeTrue();
				} finally {
					settings.respectNoIndex = savedFlag;
				}
			} );

		} );

		describe( "orphan-page seeding", function(){

			it( "crawls an orphan page and its links when passed via seedUrls", function(){
				// Seed the unlinked page. Its relative link requires the fetched URL
				// as Parser.parseHtml()'s base URI.
				var result = getInstance( "sitemapService@sitemap-spider" )
					.create(
						url      = variables.appRoot,
						seedUrls = [ variables.appRoot & "noBaseHref.cfm" ]
					);

				expect( hasPage( result.pages, variables.appRoot & "noBaseHref.cfm" ) ).toBeTrue();
				expect( hasPage( result.pages, variables.appRoot & "posts.cfm" ) ).toBeTrue();
			} );

		} );

		describe( "saveToFile via create()", function(){

			it( "writes the sitemap to disk and reports saved=true when filePath is given", function(){
				variables.savedSitemapFile = getTempDirectory() & "sitemap-task10-" & getTickCount() & ".xml";

				var result = getInstance( "sitemapService@sitemap-spider" )
					.create( url = variables.appRoot, filePath = variables.savedSitemapFile );

				expect( result.saved ).toBeTrue();
				expect( result.filePath ).toBe( variables.savedSitemapFile );
				expect( fileExists( variables.savedSitemapFile ) ).toBeTrue();
				// The file holds the same XML returned in the struct.
				expect( fileRead( variables.savedSitemapFile ) ).toBe( result.sitemap );
			} );

		} );

		describe( "sitemap index splitting via create()", function(){

			it( "splits into an index and child files when the crawl exceeds maxUrlsPerSitemap", function(){
				// Temporarily lower the per-file URL limit so the sample crawl
				// (4 valid pages) splits into more than one file. The setting is
				// the shared module-settings struct the service injects, so it is
				// restored in the finally to avoid leaking into other specs.
				var settings   = getInstance( "coldbox:moduleSettings:sitemap-spider" );
				var originalMax = settings.maxUrlsPerSitemap;
				variables.splitOutDir = getTempDirectory() & "sitemap-split-" & getTickCount() & "/";
				var indexPath  = variables.splitOutDir & "sitemap.xml";

				try {
					settings.maxUrlsPerSitemap = 2;

					var result = getInstance( "sitemapService@sitemap-spider" )
						.create( url = variables.appRoot, filePath = indexPath );

					expect( result.type ).toBe( "index" );
					expect( result.saved ).toBeTrue();
					expect( result.sitemapCount ).toBeGT( 1 );
					expect( result.sitemapCount ).toBe( result.sitemaps.len() );

					// The primary file is the served root and holds a <sitemapindex>.
					expect( fileExists( indexPath ) ).toBeTrue();
					expect( result.sitemap ).toInclude( "<sitemapindex" );

					// Each child sitemap was written beside the index under its name.
					for ( var child in result.sitemaps ) {
						expect( fileExists( child.filePath ) ).toBeTrue();
						expect( child.filePath ).toInclude( child.filename );
					}
				} finally {
					settings.maxUrlsPerSitemap = originalMax;
				}
			} );

		} );

		describe( "image sitemap via create()", function(){

			it( "records page images and emits <image:image> when includeImages is on", function(){
				// Enable images for this crawl without changing the module setting.
				var result = getInstance( "sitemapService@sitemap-spider" )
					.create( url = variables.appRoot, includeImages = true );

				// The index page carries the sample image on its page struct.
				var indexImages = pageFor( result.pages, variables.appRoot ).images;
				expect( indexImages ).toBeArray();
				expect( indexImages ).toInclude( variables.appRoot & "assets/img/sample.jpg" );

				// The sitemap XML declares the image namespace and the entry.
				expect( result.sitemap ).toInclude( "xmlns:image=" );
				expect( result.sitemap ).toInclude(
					"<image:loc>" & variables.appRoot & "assets/img/sample.jpg</image:loc>"
				);
			} );

			it( "leaves images out when the crawl passes includeImages false", function(){
				// The module setting is off by default, so this also proves the
				// default: no argument, no images.
				var result = getInstance( "sitemapService@sitemap-spider" )
					.create( url = variables.appRoot, includeImages = false );

				expect( pageFor( result.pages, variables.appRoot ).images.len() ).toBe( 0 );
				expect( result.sitemap ).notToInclude( "xmlns:image=" );
			} );

		} );

		describe( "hreflang and video sitemap extensions via create()", function(){

			it( "records alternates and emits <xhtml:link> when includeHreflang is on", function(){
				// index.cfm declares an "es" alternate on another host and an
				// "x-default" pointing at itself. Both land on the page struct and
				// in the XML, emitted exactly as declared.
				var result = getInstance( "sitemapService@sitemap-spider" )
					.create( url = variables.appRoot, includeHreflang = true );

				var alternates = pageFor( result.pages, variables.appRoot ).alternates;
				expect( alternates ).toBeArray();
				expect( alternates.len() ).toBe( 2 );
				expect( alternates[ 1 ].hreflang ).toBe( "es" );
				expect( alternates[ 1 ].href ).toBe( "https://es.example.test/" );
				expect( alternates[ 2 ].hreflang ).toBe( "x-default" );

				expect( result.sitemap ).toInclude( 'xmlns:xhtml="http://www.w3.org/1999/xhtml"' );
				expect( result.sitemap ).toInclude(
					'<xhtml:link rel="alternate" hreflang="es" href="https://es.example.test/"/>'
				);
			} );

			it( "records videos and emits <video:video> when includeVideos is on", function(){
				// index.cfm carries a <video src="./assets/video/sample.mp4"
				// poster="./assets/img/sample.jpg">. The title comes from the page
				// <title> and the description from the meta description tag.
				var result = getInstance( "sitemapService@sitemap-spider" )
					.create( url = variables.appRoot, includeVideos = true );

				var videos = pageFor( result.pages, variables.appRoot ).videos;
				expect( videos ).toBeArray();
				expect( videos.len() ).toBe( 1 );
				expect( videos[ 1 ].contentLoc ).toBe( variables.appRoot & "assets/video/sample.mp4" );
				expect( videos[ 1 ].thumbnailLoc ).toBe( variables.appRoot & "assets/img/sample.jpg" );
				expect( videos[ 1 ].title ).toBe( "Home" );
				expect( videos[ 1 ].description ).toBe( "Sample home page with a video." );

				expect( result.sitemap ).toInclude( 'xmlns:video="http://www.google.com/schemas/sitemap-video/1.1"' );
				expect( result.sitemap ).toInclude(
					"<video:video>"
					& "<video:thumbnail_loc>" & variables.appRoot & "assets/img/sample.jpg</video:thumbnail_loc>"
					& "<video:title>Home</video:title>"
					& "<video:description>Sample home page with a video.</video:description>"
					& "<video:content_loc>" & variables.appRoot & "assets/video/sample.mp4</video:content_loc>"
					& "</video:video>"
				);
			} );

			it( "reads a video from a JSON-LD block, duration included", function(){
				// video-jsonld.cfm describes its video only in a JSON-LD
				// VideoObject inside a @graph array, with no Open Graph tags and
				// no <video> element. Nothing links to that page, so it is
				// reached through seedUrls. Its own name and description win
				// over the page <title>, and PT1M33S becomes 93 seconds.
				var pageUrl = variables.appRoot & "video-jsonld.cfm";
				var result  = getInstance( "sitemapService@sitemap-spider" ).create(
					url           = variables.appRoot,
					seedUrls      = [ pageUrl ],
					includeVideos = true
				);

				var videos = pageFor( result.pages, pageUrl ).videos;
				expect( videos.len() ).toBe( 1 );
				expect( videos[ 1 ].title ).toBe( "Structured Data Clip" );
				expect( videos[ 1 ].description ).toBe( "A video described only in JSON-LD." );
				expect( videos[ 1 ].thumbnailLoc ).toBe( variables.appRoot & "assets/img/sample.jpg" );
				expect( videos[ 1 ].contentLoc ).toBe( variables.appRoot & "assets/video/jsonld.mp4" );
				expect( videos[ 1 ].playerLoc ).toBe( "https://player.example.test/embed/42" );
				expect( videos[ 1 ].duration ).toBe( 93 );

				expect( result.sitemap ).toInclude(
					"<video:content_loc>" & variables.appRoot & "assets/video/jsonld.mp4</video:content_loc>"
					& "<video:player_loc>https://player.example.test/embed/42</video:player_loc>"
					& "<video:duration>93</video:duration>"
				);
			} );

		} );

		describe( "async parallel crawl", function(){

			// The shared beforeAll crawl (variables.result) is synchronous. Crawl
			// the same sample site in parallel and assert it discovers the exact
			// same pages and bad URLs. Assertions are on the sorted sets, not visit
			// order, because parallel order is not deterministic. The test harness
			// sets maxCrawlDelay = 0, so the sample robots.txt Crawl-delay does not
			// force the crawl back to sync.
			it( "finds the same pages as the synchronous crawl", function(){
				var async = getInstance( "sitemapService@sitemap-spider" )
					.create( url = variables.appRoot, runAsync = true );

				expect( async.runAsync ).toBeTrue();
				expect( pageUrls( async.pages ).sort( "textnocase" ) )
					.toBe( pageUrls( variables.result.pages ).sort( "textnocase" ) );
				expect( structKeyArray( async.badUrls ).sort( "textnocase" ) )
					.toBe( structKeyArray( variables.result.badUrls ).sort( "textnocase" ) );
				// Compare ignored URLs and reasons without depending on worker order.
				expect( ignoredPairs( async.ignored ) ).toBe( ignoredPairs( variables.result.ignored ) );
			} );

			// Repeat the parallel crawl to catch race conditions that change pages.
			it( "produces a stable page set across repeated parallel crawls", function(){
				var expected = pageUrls( variables.result.pages ).sort( "textnocase" );
				for ( var i = 1; i <= 3; i++ ){
					var async = getInstance( "sitemapService@sitemap-spider" )
						.create( url = variables.appRoot, runAsync = true );
					expect( pageUrls( async.pages ).sort( "textnocase" ) ).toBe( expected );
				}
			} );

		} );
	}

}
