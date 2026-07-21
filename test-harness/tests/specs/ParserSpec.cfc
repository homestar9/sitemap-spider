/**
 * Regression specs for the task 04 parser correctness fixes.
 *
 * Covers the behaviors task 04 changed in Parser.cfc:
 *   - cleanUrl() trims ends, encodes interior spaces as %20 (never deletes them),
 *     normalizes backslashes, and strips the fragment including the "#".
 *   - getCanonicalUrl() reads settings.canonicalHeaderPattern and finds a canonical
 *     entry anywhere in a single- or multi-relation Link header, quoted or unquoted.
 *   - getLastModified() parses the HTTP Last-Modified header (RFC 1123) or a
 *     meta-tag date into a real date object, or returns "" (task 10).
 *
 * Task 05 adds coverage for getLinks() (nofollow filtering, relative-href
 * resolution, duplicate removal, notAllowedPattern rejection) and isNoFollow()
 * (single- and multi-value rel attributes).
 *
 * Task 06 makes Parser the single owner of the URL-allowance rule, so the
 * isUrlAllowed() coverage moved here from CrawlerSpec.
 *
 * cleanUrl() and isUrlAllowed() are public; isNoFollow() is private and exposed
 * here with TestBox makePublic().
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
		variables.jsoup  = getInstance( "javaloader:org.jsoup.Jsoup" );
		// cleanUrl() and isUrlAllowed() are public (task 06 made Parser the single
		// owner of both). isNoFollow() is still private, so expose it here.
		makePublic( variables.parser, "isNoFollow" );
		// getLinks()/isNoFollow()/isUrlAllowed() filter by host, so set the host
		// the fixtures use.
		variables.parser.setHostName( "example.test" );
	}

	function afterAll(){
		super.afterAll();
	}

	// Parses html with an explicit base URI so jsoup's abs:href resolves relative
	// hrefs. parser.parseHtml() sets no base URI, so it cannot be used here.
	private any function parseWithBase( required string html, required string baseUri ){
		return variables.jsoup.parse( arguments.html, arguments.baseUri );
	}

	// Parses an anchor tag and returns its jsoup element, for isNoFollow() tests.
	private any function anchor( required string tag ){
		return variables.jsoup.parse( arguments.tag ).select( "a" ).first();
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

			describe( "isUrlAllowed()", function(){

				// Moved from CrawlerSpec in task 06: Parser is now the single owner of
				// the URL-allowance rule and the Crawler delegates to it. The host is
				// set to example.test in beforeAll, which isUrlAllowed() checks.

				it( "allows a normal .cfm page URL on the host", function(){
					expect( variables.parser.isUrlAllowed( "http://example.test/contact.cfm" ) ).toBeTrue();
				} );

				it( "rejects image, mailto, and tel URLs", function(){
					expect( variables.parser.isUrlAllowed( "http://example.test/assets/img/sample.jpg" ) ).toBeFalse();
					expect( variables.parser.isUrlAllowed( "mailto:support@example.test" ) ).toBeFalse();
					expect( variables.parser.isUrlAllowed( "tel:+18005551212" ) ).toBeFalse();
				} );

				it( "rejects an off-host URL", function(){
					expect( variables.parser.isUrlAllowed( "http://other.test/contact.cfm" ) ).toBeFalse();
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

				it( "parses the RFC 1123 Last-Modified header into a real date", function(){
					var fetchResult = { headers : { "Last-Modified" : "Wed, 21 Oct 2026 07:28:00 GMT" } };
					var result      = variables.parser.getLastModified( fetchResult, {} );
					expect( isDate( result ) ).toBeTrue();
					// The exact day can shift by one in a far-west timezone; year and
					// month stay put for this mid-month value, so assert those.
					expect( year( result ) ).toBe( 2026 );
					expect( month( result ) ).toBe( 10 );
				} );

				it( "returns empty when there is no Last-Modified header", function(){
					var fetchResult = { headers : {} };
					expect( variables.parser.getLastModified( fetchResult ) ).toBe( "" );
				} );

				it( "falls back to an article:modified_time meta tag when no header is present", function(){
					var page = variables.parser.parseHtml(
						'<html><head><meta property="article:modified_time" content="2026-07-15T10:00:00+00:00"></head></html>'
					);
					var result = variables.parser.getLastModified( { headers : {} }, page );
					// This value carries a UTC offset; the exact calendar day after
					// conversion depends on the server timezone, so only assert it
					// parsed into a real date, not the day.
					expect( isDate( result ) ).toBeTrue();
				} );

				it( "falls back to a name=last-modified meta tag when no header is present", function(){
					var page = variables.parser.parseHtml(
						'<html><head><meta name="last-modified" content="2026-01-02"></head></html>'
					);
					var result = variables.parser.getLastModified( { headers : {} }, page );
					expect( isDate( result ) ).toBeTrue();
					expect( dateFormat( result, "yyyy-mm-dd" ) ).toBe( "2026-01-02" );
				} );

			} );

			describe( "getLinks()", function(){

				it( "resolves a relative href to an absolute URL", function(){
					var page = parseWithBase(
						'<a href="page.cfm">link</a>',
						"http://example.test/dir/"
					);
					expect( variables.parser.getLinks( page ) ).toInclude( "http://example.test/dir/page.cfm" );
				} );

				it( "drops a link marked rel=nofollow", function(){
					var page = parseWithBase(
						'<a href="http://example.test/keep.cfm">keep</a>'
						& '<a href="http://example.test/skip.cfm" rel="nofollow">skip</a>',
						"http://example.test/"
					);
					var links = variables.parser.getLinks( page );
					expect( links ).toInclude( "http://example.test/keep.cfm" );
					expect( links.findNoCase( "http://example.test/skip.cfm" ) ).toBe( 0 );
				} );

				it( "returns a duplicated href only once", function(){
					var page = parseWithBase(
						'<a href="http://example.test/dup.cfm">one</a>'
						& '<a href="http://example.test/dup.cfm">two</a>',
						"http://example.test/"
					);
					var links = variables.parser.getLinks( page );
					var occurrences = 0;
					for ( var url in links ) {
						if ( url == "http://example.test/dup.cfm" ) {
							occurrences++;
						}
					}
					expect( occurrences ).toBe( 1 );
				} );

				it( "drops image and off-host links", function(){
					var page = parseWithBase(
						'<a href="http://example.test/pic.jpg">image</a>'
						& '<a href="http://other.test/x.cfm">other host</a>',
						"http://example.test/"
					);
					var links = variables.parser.getLinks( page );
					expect( links.findNoCase( "http://example.test/pic.jpg" ) ).toBe( 0 );
					expect( links.findNoCase( "http://other.test/x.cfm" ) ).toBe( 0 );
				} );

			} );

			describe( "getMetaRefreshUrl()", function(){

				it( "resolves a relative target against the base URL", function(){
					var page = variables.parser.parseHtml(
						'<html><head><meta http-equiv="refresh" content="3;url=redirect-new.cfm"></head></html>'
					);
					expect( variables.parser.getMetaRefreshUrl( page, "http://example.test/dir/" ) )
						.toBe( "http://example.test/dir/redirect-new.cfm" );
				} );

				it( "accepts an already-absolute target", function(){
					var page = variables.parser.parseHtml(
						'<html><head><meta http-equiv="refresh" content="0;url=http://example.test/new.cfm"></head></html>'
					);
					expect( variables.parser.getMetaRefreshUrl( page, "http://example.test/old.cfm" ) )
						.toBe( "http://example.test/new.cfm" );
				} );

				it( "handles uppercase URL and extra spacing", function(){
					var page = variables.parser.parseHtml(
						'<html><head><meta http-equiv="refresh" content="0; URL=next.cfm"></head></html>'
					);
					expect( variables.parser.getMetaRefreshUrl( page, "http://example.test/" ) )
						.toBe( "http://example.test/next.cfm" );
				} );

				it( "returns empty when there is no meta-refresh tag", function(){
					var page = variables.parser.parseHtml( "<html><head></head><body></body></html>" );
					expect( variables.parser.getMetaRefreshUrl( page, "http://example.test/" ) ).toBe( "" );
				} );

				it( "returns empty for a refresh with no url= part", function(){
					// content="5" reloads the same page; it is not a redirect.
					var page = variables.parser.parseHtml(
						'<html><head><meta http-equiv="refresh" content="5"></head></html>'
					);
					expect( variables.parser.getMetaRefreshUrl( page, "http://example.test/" ) ).toBe( "" );
				} );

			} );

			describe( "isNoFollow()", function(){

				it( "is true for rel=nofollow", function(){
					expect( variables.parser.isNoFollow( anchor( '<a href="/x" rel="nofollow">x</a>' ) ) ).toBeTrue();
				} );

				it( "is true when nofollow is one of several rel values", function(){
					expect( variables.parser.isNoFollow( anchor( '<a href="/x" rel="external nofollow">x</a>' ) ) ).toBeTrue();
				} );

				it( "is false for a non-nofollow rel value", function(){
					expect( variables.parser.isNoFollow( anchor( '<a href="/x" rel="noopener">x</a>' ) ) ).toBeFalse();
				} );

				it( "is false when there is no rel attribute", function(){
					expect( variables.parser.isNoFollow( anchor( '<a href="/x">x</a>' ) ) ).toBeFalse();
				} );

			} );

		} );
	}

}
