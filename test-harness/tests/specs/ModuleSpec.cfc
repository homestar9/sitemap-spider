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
		// - disallow.cfm is currently absent only because nothing links to it.
		//   robots.txt Disallow enforcement lands in task 07; once it does, add
		//   a reachable link to disallow.cfm and this assertion still holds.
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
		super.afterAll();
	}

	/*********************************** BDD SUITES ***********************************/

	function run(){
		describe( "Sitemap Tests", function(){

			it( "returns a struct with the expected top-level keys", function(){
				expect( variables.result ).toBeStruct();
				expect( variables.result ).toHaveKey( "pages,badUrls,processedUrls,duration" );
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
	}

}
