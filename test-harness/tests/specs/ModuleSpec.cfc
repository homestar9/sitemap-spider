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
		//   disallowedUrls. See the "reports a robots-disallowed page" spec below.
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

	function run(){
		describe( "Sitemap Tests", function(){

			it( "returns a struct with the expected top-level keys", function(){
				expect( variables.result ).toBeStruct();
				expect( variables.result ).toHaveKey( "pages,badUrls,processedUrls,disallowedUrls,duration,filePath,saved" );
			} );

			it( "does not save a file when no filePath is given", function(){
				// The shared baseline crawl passed no filePath, so saved is false.
				expect( variables.result.saved ).toBeFalse();
				expect( variables.result.filePath ).toBe( "" );
			} );

			it( "includes the reachable valid pages", function(){
				for ( var page in variables.testData.validPages ) {
					expect( variables.result.pages ).toHaveKey( variables.appRoot & page );
				}
			} );

			it( "excludes nofollow and unreferenced pages", function(){
				for ( var page in variables.testData.ignoredPages ) {
					expect( variables.result.pages ).notToHaveKey( variables.appRoot & page );
				}
			} );

			it( "reports a robots-disallowed page in disallowedUrls", function(){
				// index.cfm links to disallow.cfm, but robots.txt disallows it, so
				// it is skipped (never fetched) and recorded in disallowedUrls.
				expect( variables.result.disallowedUrls ).toBeArray();
				expect( variables.result.disallowedUrls ).toInclude( variables.appRoot & "disallow.cfm" );
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

				expect( result.pages ).toHaveKey( newUrl );
				expect( result.pages ).notToHaveKey( oldUrl );
			} );

			it( "records the final URL of an HTTP (cflocation) redirect", function(){
				var oldUrl = variables.appRoot & "location-old.cfm";
				var newUrl = variables.appRoot & "location-new.cfm";

				var result = getInstance( "sitemapService@sitemap-spider" ).create( oldUrl );

				expect( result.pages ).toHaveKey( newUrl );
				expect( result.pages ).notToHaveKey( oldUrl );
			} );

			it( "does not carry pages over from a previous crawl", function(){
				// Regression for the Crawler state-reset fix: WireBox may hand back a
				// cached Crawler, so crawl() resets its state at the top. A first crawl
				// of the meta-refresh interstitial records redirect-new.cfm; a second,
				// unrelated crawl must not still contain it.
				var service = getInstance( "sitemapService@sitemap-spider" );
				service.create( variables.appRoot & "redirect-old.cfm" );
				var second = service.create( variables.appRoot & "location-old.cfm" );

				expect( second.pages ).toHaveKey( variables.appRoot & "location-new.cfm" );
				expect( second.pages ).notToHaveKey( variables.appRoot & "redirect-new.cfm" );
			} );

			// js-redirect-old.cfm redirects with JavaScript (location.replace), which
			// jsoup cannot see. This spec stays skipped under the default jsoup
			// backend; the real assertion for the JavaScript redirect (target:
			// contact.cfm, where the fixture's location.replace points) lives in
			// PlaywrightSpec, which runs the Playwright backend.
			xit( "follows a JavaScript redirect (requires Playwright, see PlaywrightSpec)", function(){
				var oldUrl = variables.appRoot & "js-redirect-old.cfm";
				var newUrl = variables.appRoot & "contact.cfm";

				var result = getInstance( "sitemapService@sitemap-spider" ).create( oldUrl );

				expect( result.pages ).toHaveKey( newUrl );
				expect( result.pages ).notToHaveKey( oldUrl );
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

		describe( "async parallel crawl", function(){

			// The shared beforeAll crawl (variables.result) is synchronous. Crawl
			// the same sample site in parallel and assert it discovers the exact
			// same pages, bad URLs, and disallowed URLs. Assertions are on the
			// sorted key sets, not visit order, because parallel order is not
			// deterministic. The test harness sets maxCrawlDelay = 0, so the
			// sample robots.txt Crawl-delay does not force the crawl back to sync.
			it( "finds the same pages as the synchronous crawl", function(){
				var async = getInstance( "sitemapService@sitemap-spider" )
					.create( url = variables.appRoot, runAsync = true );

				expect( async.runAsync ).toBeTrue();
				expect( structKeyArray( async.pages ).sort( "textnocase" ) )
					.toBe( structKeyArray( variables.result.pages ).sort( "textnocase" ) );
				expect( structKeyArray( async.badUrls ).sort( "textnocase" ) )
					.toBe( structKeyArray( variables.result.badUrls ).sort( "textnocase" ) );
				expect( async.disallowedUrls.sort( "textnocase" ) )
					.toBe( variables.result.disallowedUrls.sort( "textnocase" ) );
			} );

			// A race that only sometimes surfaces would make the recorded page set
			// vary between runs. Crawl a few times and assert every run produces the
			// same set, so a nondeterministic claim/counter bug fails the suite.
			it( "produces a stable page set across repeated parallel crawls", function(){
				var expected = structKeyArray( variables.result.pages ).sort( "textnocase" );
				for ( var i = 1; i <= 3; i++ ){
					var async = getInstance( "sitemapService@sitemap-spider" )
						.create( url = variables.appRoot, runAsync = true );
					expect( structKeyArray( async.pages ).sort( "textnocase" ) ).toBe( expected );
				}
			} );

		} );
	}

}
