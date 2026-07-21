/**
 * Regression specs for the task 04 parser correctness fixes.
 *
 * Covers the behaviors task 04 changed in Parser.cfc:
 *   - cleanUrl() trims ends, encodes interior spaces as %20 (never deletes them),
 *     normalizes backslashes, and strips the fragment including the "#".
 *   - getCanonicalUrl() reads settings.canonicalHeaderPattern and finds a canonical
 *     entry anywhere in a single- or multi-relation Link header, quoted or unquoted.
 *   - getLastModified() accepts the optional second parsedPage argument.
 *
 * cleanUrl() is private, exposed here with TestBox makePublic().
 *
 * Local run recipe:
 *   1. box server start serverConfigFile=server-adobe@2023.json
 *   2. box testbox run runner="http://localhost:61002/tests/runner.cfm" bundles="tests.specs.ParserSpec"
 */
component extends="coldbox.system.testing.BaseTestCase" appMapping="root" {

	function beforeAll(){
		super.beforeAll();
		setup();

		variables.parser = getInstance( "Parser@sitemap-spider" );
		makePublic( variables.parser, "cleanUrl" );
	}

	function afterAll(){
		super.afterAll();
	}

	function run(){
		describe( "Parser correctness fixes", function(){

			describe( "cleanUrl()", function(){

				it( "preserves an already-encoded %20", function(){
					expect( variables.parser.cleanUrl( "http://example.test/a%20b.cfm" ) )
						.toBe( "http://example.test/a%20b.cfm" );
				} );

				it( "encodes a raw interior space as %20", function(){
					expect( variables.parser.cleanUrl( "http://example.test/a b.cfm" ) )
						.toBe( "http://example.test/a%20b.cfm" );
				} );

				it( "trims leading and trailing whitespace", function(){
					expect( variables.parser.cleanUrl( "  http://example.test/a.cfm  " ) )
						.toBe( "http://example.test/a.cfm" );
				} );

				it( "strips the fragment including the hash", function(){
					// "##" is a literal single "#" in a CFML string.
					expect( variables.parser.cleanUrl( "http://example.test/a.cfm##section" ) )
						.toBe( "http://example.test/a.cfm" );
				} );

				it( "converts backslashes to forward slashes", function(){
					expect( variables.parser.cleanUrl( "http:\\example.test\a.cfm" ) )
						.toBe( "http://example.test/a.cfm" );
				} );

			} );

			describe( "getCanonicalUrl() from the Link header", function(){

				it( "reads a single-relation quoted rel", function(){
					var fetchResult = { headers : { "Link" : '<https://example.test/page.cfm>; rel="canonical"' } };
					expect( variables.parser.getCanonicalUrl( fetchResult ) ).toBe( "https://example.test/page.cfm" );
				} );

				it( "reads canonical when it sits between other relations", function(){
					var fetchResult = { headers : { "Link" : '<https://example.test/prev.cfm>; rel="prev", <https://example.test/page.cfm>; rel="canonical", <https://example.test/next.cfm>; rel="next"' } };
					expect( variables.parser.getCanonicalUrl( fetchResult ) ).toBe( "https://example.test/page.cfm" );
				} );

				it( "reads an unquoted rel", function(){
					var fetchResult = { headers : { "Link" : '<https://example.test/page.cfm>; rel=canonical' } };
					expect( variables.parser.getCanonicalUrl( fetchResult ) ).toBe( "https://example.test/page.cfm" );
				} );

				it( "returns empty when no canonical relation is present", function(){
					var fetchResult = { headers : { "Link" : '<https://example.test/next.cfm>; rel="next"' } };
					expect( variables.parser.getCanonicalUrl( fetchResult ) ).toBe( "" );
				} );

			} );

			describe( "getCanonicalUrl() from a parsed page", function(){

				it( "reads canonical from a parsed <link rel=canonical>", function(){
					var page = variables.parser.parseHtml(
						'<html><head><link rel="canonical" href="https://example.test/canonical.cfm"></head><body></body></html>'
					);
					var fetchResult = { headers : {} };
					expect( variables.parser.getCanonicalUrl( fetchResult, page ) ).toBe( "https://example.test/canonical.cfm" );
				} );

			} );

			describe( "getLastModified()", function(){

				it( "accepts an optional parsedPage and returns the Last-Modified header", function(){
					var fetchResult = { headers : { "Last-Modified" : "Wed, 21 Oct 2026 07:28:00 GMT" } };
					expect( variables.parser.getLastModified( fetchResult, {} ) ).toBe( "Wed, 21 Oct 2026 07:28:00 GMT" );
				} );

				it( "returns empty when there is no Last-Modified header", function(){
					var fetchResult = { headers : {} };
					expect( variables.parser.getLastModified( fetchResult ) ).toBe( "" );
				} );

			} );

		} );
	}

}
