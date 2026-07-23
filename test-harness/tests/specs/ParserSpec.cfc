/**
 * Regression specs for the task 04 parser correctness fixes.
 *
 * Covers the behaviors task 04 changed in Parser.cfc:
 *   - cleanUrl() trims ends, encodes interior spaces as %20 (never deletes them),
 *     normalizes backslashes, and strips the fragment including the "#".
 *   - getCanonicalUrl() tokenizes the Link header and finds a canonical entry
 *     anywhere in a single- or multi-relation Link header, quoted or unquoted, in
 *     any parameter position (task 17).
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

			// Task 16 folded the URL normalization policy into cleanUrl's final
			// step (Parser.normalizeUrl): lowercase scheme + host, preserve path
			// case, strip session/tracking params from the query and a
			// ";jsessionid=" path parameter.
			describe( "cleanUrl() URL normalization", function(){

				it( "lowercases the scheme and host but preserves path case", function(){
					expect( variables.parser.cleanUrl( "HTTP://EXAMPLE.TEST/MyPage.CFM" ) )
						.toBe( "http://example.test/MyPage.CFM" );
				} );

				it( "strips CFID/CFTOKEN and drops the now-empty query", function(){
					expect( variables.parser.cleanUrl( "http://example.test/a.cfm?CFID=1&CFTOKEN=2" ) )
						.toBe( "http://example.test/a.cfm" );
				} );

				it( "strips jsessionid from the query but keeps other params", function(){
					expect( variables.parser.cleanUrl( "http://example.test/a.cfm?jsessionid=X&id=5" ) )
						.toBe( "http://example.test/a.cfm?id=5" );
				} );

				it( "strips a ;jsessionid= path parameter", function(){
					expect( variables.parser.cleanUrl( "http://example.test/a.cfm;jsessionid=ABC123" ) )
						.toBe( "http://example.test/a.cfm" );
				} );

				it( "strips a tracking param but keeps a normal one", function(){
					expect( variables.parser.cleanUrl( "http://example.test/a.cfm?utm_source=news&id=5" ) )
						.toBe( "http://example.test/a.cfm?id=5" );
				} );

				it( "leaves a non-http scheme untouched", function(){
					// mailto: is filtered later by isUrlAllowed, so cleanUrl must pass
					// it through without trying to normalize it.
					expect( variables.parser.cleanUrl( "mailto:Support@example.test" ) )
						.toBe( "mailto:Support@example.test" );
				} );

				it( "is idempotent on an already-normalized URL", function(){
					var once = variables.parser.cleanUrl( "HTTP://EXAMPLE.TEST/MyPage.CFM?jsessionid=Z&id=5" );
					expect( variables.parser.cleanUrl( once ) ).toBe( once );
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

				// Task 17 tokenizer hardening: rel may sit after other params, an
				// exact "canonical" token is required, and commas inside a URL or a
				// quoted param value must not split an entry.

				it( "finds canonical when rel is not the first parameter", function(){
					var fetchResult = { headers : { "Link" : '<https://example.test/page.cfm>; type="text/html"; rel="canonical"' } };
					expect( variables.parser.getCanonicalUrl( fetchResult ) ).toBe( "https://example.test/page.cfm" );
				} );

				it( "does not treat rel=canonicalize as canonical", function(){
					var fetchResult = { headers : { "Link" : '<https://example.test/page.cfm>; rel="canonicalize"' } };
					expect( variables.parser.getCanonicalUrl( fetchResult ) ).toBe( "" );
				} );

				it( "matches canonical among several space-separated rel tokens", function(){
					var fetchResult = { headers : { "Link" : '<https://example.test/page.cfm>; rel="alternate canonical"' } };
					expect( variables.parser.getCanonicalUrl( fetchResult ) ).toBe( "https://example.test/page.cfm" );
				} );

				it( "keeps a comma inside a URL from splitting the entry", function(){
					var fetchResult = { headers : { "Link" : '<https://example.test/a,b.cfm>; rel="canonical"' } };
					expect( variables.parser.getCanonicalUrl( fetchResult ) ).toBe( "https://example.test/a,b.cfm" );
				} );

				it( "keeps a comma inside a quoted param value from splitting the entry", function(){
					var fetchResult = { headers : { "Link" : '<https://example.test/prev.cfm>; rel="prev"; title="Smith, John", <https://example.test/page.cfm>; rel="canonical"' } };
					expect( variables.parser.getCanonicalUrl( fetchResult ) ).toBe( "https://example.test/page.cfm" );
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

				it( "resolves a relative canonical href against the parse base URI", function(){
					// With task 17, parseHtml can carry a base URI, so a relative
					// <link rel=canonical> resolves to an absolute URL via abs:href.
					var page = variables.parser.parseHtml(
						'<html><head><link rel="canonical" href="canonical.cfm"></head></html>',
						"http://example.test/dir/"
					);
					var fetchResult = { headers : {} };
					expect( variables.parser.getCanonicalUrl( fetchResult, page ) ).toBe( "http://example.test/dir/canonical.cfm" );
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

				it( "returns a struct with links and ignored arrays", function(){
					var page = parseWithBase(
						'<a href="page.cfm">link</a>',
						"http://example.test/dir/"
					);
					var result = variables.parser.getLinks( page );
					expect( result ).toBeStruct();
					expect( result ).toHaveKey( "links,ignored" );
					expect( result.links ).toBeArray();
					expect( result.ignored ).toBeArray();
				} );

				it( "resolves a relative href to an absolute URL", function(){
					var page = parseWithBase(
						'<a href="page.cfm">link</a>',
						"http://example.test/dir/"
					);
					expect( variables.parser.getLinks( page ).links ).toInclude( "http://example.test/dir/page.cfm" );
				} );

				it( "resolves a relative href when parseHtml is given a base URI and the page has no <base> tag", function(){
					// Exercises the real production path: task 17 lets parseHtml take
					// a base URI, so a page with a relative href and no <base> tag
					// still yields absolute links. Before task 17 this returned [].
					var page = variables.parser.parseHtml(
						'<html><body><a href="page.cfm">link</a></body></html>',
						"http://example.test/dir/"
					);
					expect( variables.parser.getLinks( page ).links ).toInclude( "http://example.test/dir/page.cfm" );
				} );

				it( "drops a link marked rel=nofollow from links", function(){
					var page = parseWithBase(
						'<a href="http://example.test/keep.cfm">keep</a>'
						& '<a href="http://example.test/skip.cfm" rel="nofollow">skip</a>',
						"http://example.test/"
					);
					var links = variables.parser.getLinks( page ).links;
					expect( links ).toInclude( "http://example.test/keep.cfm" );
					expect( links.findNoCase( "http://example.test/skip.cfm" ) ).toBe( 0 );
				} );

				it( "reports a nofollow link in ignored with reason 'nofollow'", function(){
					var page = parseWithBase(
						'<a href="http://example.test/keep.cfm">keep</a>'
						& '<a href="http://example.test/skip.cfm" rel="nofollow">skip</a>',
						"http://example.test/"
					);
					var ignored = variables.parser.getLinks( page ).ignored;
					expect( ignored.len() ).toBe( 1 );
					expect( ignored[ 1 ].url ).toBe( "http://example.test/skip.cfm" );
					expect( ignored[ 1 ].reason ).toBe( "nofollow" );
				} );

				it( "does not report off-host or image links as ignored", function(){
					// Off-host and image links are dropped silently, not reported,
					// so a page with only those has an empty ignored list.
					var page = parseWithBase(
						'<a href="http://example.test/pic.jpg">image</a>'
						& '<a href="http://other.test/x.cfm">other host</a>',
						"http://example.test/"
					);
					expect( variables.parser.getLinks( page ).ignored ).toBeEmpty();
				} );

				it( "returns a duplicated href only once", function(){
					var page = parseWithBase(
						'<a href="http://example.test/dup.cfm">one</a>'
						& '<a href="http://example.test/dup.cfm">two</a>',
						"http://example.test/"
					);
					var links = variables.parser.getLinks( page ).links;
					var occurrences = 0;
					for ( var link in links ) {
						if ( link == "http://example.test/dup.cfm" ) {
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
					var links = variables.parser.getLinks( page ).links;
					expect( links.findNoCase( "http://example.test/pic.jpg" ) ).toBe( 0 );
					expect( links.findNoCase( "http://other.test/x.cfm" ) ).toBe( 0 );
				} );

			} );

			describe( "getImages()", function(){

					it( "resolves a relative img src to an absolute URL", function(){
						var page = parseWithBase(
							'<img src="pic.jpg">',
							"http://example.test/dir/"
						);
						expect( variables.parser.getImages( page ) ).toInclude( "http://example.test/dir/pic.jpg" );
					} );

					it( "keeps off-host (CDN) images", function(){
						// Unlike page links, images are not host-filtered.
						var page = parseWithBase(
							'<img src="http://cdn.other/a.png">',
							"http://example.test/"
						);
						expect( variables.parser.getImages( page ) ).toInclude( "http://cdn.other/a.png" );
					} );

					it( "skips empty and data: URIs", function(){
						var page = parseWithBase(
							'<img src="">'
							& '<img src="data:image/png;base64,AAAA">'
							& '<img src="real.jpg">',
							"http://example.test/"
						);
						var images = variables.parser.getImages( page );
						expect( images.len() ).toBe( 1 );
						expect( images ).toInclude( "http://example.test/real.jpg" );
					} );

					it( "returns a duplicated image only once", function(){
						var page = parseWithBase(
							'<img src="http://example.test/dup.jpg">'
							& '<img src="http://example.test/dup.jpg">',
							"http://example.test/"
						);
						expect( variables.parser.getImages( page ).len() ).toBe( 1 );
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
