/**
 * Regression specs for the task 03 crawler correctness fixes.
 *
 * Covers the two behaviors that task 03 changed in Crawler.cfc:
 *   - getPriority() now clamps to a 0.1 floor.
 *   - isUrlAllowed() no longer inverts its reMatch arguments, so notAllowedPattern
 *     actually filters images/js/css/mailto/tel.
 *
 * Both are private methods, exposed here with TestBox makePublic().
 *
 * Local run recipe:
 *   1. box server start serverConfigFile=server-adobe@2023.json
 *   2. box testbox run runner="http://localhost:61002/tests/runner.cfm" bundles="tests.specs.CrawlerSpec"
 */
component extends="coldbox.system.testing.BaseTestCase" appMapping="root" {

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
	}

}
