/**
 * Baseline integration spec for the sitemap-spider module.
 *
 * It crawls the sample site under tests/resources/sample-site and pins the
 * crawler's CURRENT behavior so later tasks have a trustworthy green starting
 * point. Where current behavior is a known limitation that a later task will
 * change, the assertion pins today's value and carries a TODO(task NN) note
 * instead of asserting the eventual value.
 *
 * Local run recipe:
 *   1. box server start serverConfigFile=server-adobe@2023.json
 *   2. box testbox run runner="http://localhost:61002/tests/runner.cfm" bundles="tests.specs.ModuleSpec"
 *
 * The runner port (61002) must match the web port in the server-*.json config
 * that is running.
 */
component extends="coldbox.system.testing.BaseTestCase" appMapping="root" {

	variables.serverRoot = "http#( CGI.HTTPS == "on" ? 's' : '' )#://" & CGI.HTTP_HOST & "/";

	variables.testData = {
		// Pages the crawl reaches and lists. Keys are relative to appRoot.
		// "about/" (not "about/index.cfm") because about/index.cfm declares a
		// canonical URL of "about/", so the page is stored under the canonical.
		validPages = [
			"",
			"about/",
			"contact.cfm",
			"privacy.cfm"
		],
		// Pages that must NOT appear in the sitemap.
		// - nofollow.cfm is linked from index.cfm with rel="nofollow", so the
		//   parser skips it. This is real v1 behavior.
		// - disallow.cfm IS linked from index.cfm (task 07) but robots.txt has
		//   "Disallow: /disallow.cfm", so the crawler skips it and records it in
		//   ignored with reason "disallowed". See the ignored-reporting spec below.
		ignoredPages = [
			"disallow.cfm",
			"nofollow.cfm"
		]
	};

	/*********************************** LIFE CYCLE Methods ***********************************/

	function beforeAll(){
		super.beforeAll();
		setup();

		// Crawl the sample site once and share the result across the specs below.
		variables.appRoot = variables.serverRoot & "tests/resources/sample-site/";
		var sitemapService = getInstance( "sitemapService@sitemap-spider" );
		variables.result = sitemapService.create( variables.appRoot );
	}

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

	/*********************************** BDD SUITES ***********************************/

	// Turns an ignored list (array of { url, reason }) into a sorted array of
	// "url|reason" strings, so a sync and a parallel crawl can be compared without
	// depending on order.
	private array function ignoredPairs( required array ignored ){
		var pairs = [];
		for ( var entry in arguments.ignored ){
			pairs.append( entry.url & "|" & entry.reason );
		}
		return pairs.sort( "textnocase" );
	}

	// result.pages is now an array of page structs (each with a url field), not a
	// struct keyed by URL. These helpers replace the old toHaveKey/structKeyArray
	// idioms.

	// Every page's url field, for set comparisons.
	private array function pageUrls( required array pages ){
		var out = [];
		for ( var page in arguments.pages ){
			out.append( page.url );
		}
		return out;
	}

	// True when some page's url matches (exact). The sample-site URLs compared here
	// are same-case, so a plain equality check is enough.
	private boolean function hasPage( required array pages, required string url ){
		for ( var page in arguments.pages ){
			if ( page.url == arguments.url ){
				return true;
			}
		}
		return false;
	}

	// Returns the page struct whose url matches, or throws when none does (so a
	// spec that reads a field off it fails loudly).
	private struct function pageFor( required array pages, required string url ){
		for ( var page in arguments.pages ){
			if ( page.url == arguments.url ){
				return page;
			}
		}
		throw( type = "TestFailure", message = "No page recorded for #arguments.url#" );
	}

	function run(){
		describe( "Sitemap Tests", function(){

			it( "returns a struct with the expected top-level keys", function(){
				expect( variables.result ).toBeStruct();
				expect( variables.result ).toHaveKey( "pages,badUrls,processedUrls,ignored,duration,filePath,saved" );
				// The disallowedUrls key was removed (task 23); robots blocks live in ignored.
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
				// index.cfm links nofollow.cfm with rel="nofollow" (dropped by the
				// parser) and disallow.cfm which robots.txt blocks (dropped by the
				// crawler). Both appear in the ignored list with the right reason.
				// disallow.cfm is reported only in ignored now (the disallowedUrls
				// array was removed in task 23).
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
				// Regression for the Crawler state-reset fix: WireBox may hand back a
				// cached Crawler, so crawl() resets its state at the top. A first crawl
				// of the meta-refresh interstitial records redirect-new.cfm; a second,
				// unrelated crawl must not still contain it.
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

		describe( "orphan-page seeding", function(){

			it( "crawls an orphan page and its links when passed via seedUrls", function(){
				// noBaseHref.cfm is not linked from any reachable page, so the
				// baseline crawl never sees it. Seeding it directly lets the crawl
				// reach it, and it links to posts.cfm with a base-less relative href.
				// posts.cfm shows up only if the crawler passes the fetched URL as the
				// parse base (the task 17 fix) — this is the first end-to-end test of
				// that path.
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
				// index.cfm carries an <img src="./assets/img/sample.jpg">. With
				// includeImages on, that image is collected on the page struct and
				// the sitemap XML emits an <image:image> entry with the image
				// namespace. The setting is the shared module-settings struct, so it
				// is restored in the finally to avoid leaking into other specs.
				var settings = getInstance( "coldbox:moduleSettings:sitemap-spider" );
				var original = settings.includeImages;
				try {
					settings.includeImages = true;

					var result = getInstance( "sitemapService@sitemap-spider" )
						.create( variables.appRoot );

					// The index page carries the sample image on its page struct.
					var indexImages = pageFor( result.pages, variables.appRoot ).images;
					expect( indexImages ).toBeArray();
					expect( indexImages ).toInclude( variables.appRoot & "assets/img/sample.jpg" );

					// The sitemap XML declares the image namespace and the entry.
					expect( result.sitemap ).toInclude( "xmlns:image=" );
					expect( result.sitemap ).toInclude(
						"<image:loc>" & variables.appRoot & "assets/img/sample.jpg</image:loc>"
					);
				} finally {
					settings.includeImages = original;
				}
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
				// The ignored list (array of { url, reason }) must match too. Compare
				// sorted "url|reason" strings so order does not matter. Robots blocks
				// (reason "disallowed") are part of this, so it also covers what the
				// removed disallowedUrls comparison used to check.
				expect( ignoredPairs( async.ignored ) ).toBe( ignoredPairs( variables.result.ignored ) );
			} );

			// A race that only sometimes surfaces would make the recorded page set
			// vary between runs. Crawl a few times and assert every run produces the
			// same set, so a nondeterministic claim/counter bug fails the suite.
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
