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

				it( "collapses repeated path slashes but preserves a trailing slash", function(){
					expect( variables.parser.cleanUrl( "http://example.test//about/" ) )
						.toBe( "http://example.test/about/" );
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

				it( "keeps slashless and trailing-slash paths distinct and idempotent", function(){
					var slashless = variables.parser.cleanUrl( "http://example.test/about" );
					var trailing  = variables.parser.cleanUrl( "http://example.test/about/" );

					expect( slashless ).toBe( "http://example.test/about" );
					expect( trailing ).toBe( "http://example.test/about/" );
					expect( trailing ).notToBe( slashless );
					expect( variables.parser.cleanUrl( slashless ) ).toBe( slashless );
					expect( variables.parser.cleanUrl( trailing ) ).toBe( trailing );
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

			describe( "getAlternateLinks()", function(){

				it( "returns a struct per alternate with hreflang and href", function(){
					var page = parseWithBase(
						'<link rel="alternate" hreflang="es" href="https://es.example.test/">'
						& '<link rel="alternate" hreflang="fr" href="https://fr.example.test/">',
						"http://example.test/"
					);
					var alternates = variables.parser.getAlternateLinks( page );
					expect( alternates.len() ).toBe( 2 );
					expect( alternates[ 1 ].hreflang ).toBe( "es" );
					expect( alternates[ 1 ].href ).toBe( "https://es.example.test/" );
					expect( alternates[ 2 ].hreflang ).toBe( "fr" );
					expect( alternates[ 2 ].href ).toBe( "https://fr.example.test/" );
				} );

				it( "resolves a relative alternate href against the base URI", function(){
					var page = parseWithBase(
						'<link rel="alternate" hreflang="es" href="es/page.cfm">',
						"http://example.test/dir/"
					);
					var alternates = variables.parser.getAlternateLinks( page );
					expect( alternates[ 1 ].href ).toBe( "http://example.test/dir/es/page.cfm" );
				} );

				it( "keeps off-host alternates verbatim", function(){
					// hreflang points at other-language versions, which usually live
					// on other hosts, so alternates are never host-filtered.
					var page = parseWithBase(
						'<link rel="alternate" hreflang="de" href="https://example.de/seite.cfm?a=1&b=2">',
						"http://example.test/"
					);
					var alternates = variables.parser.getAlternateLinks( page );
					expect( alternates.len() ).toBe( 1 );
					expect( alternates[ 1 ].href ).toBe( "https://example.de/seite.cfm?a=1&b=2" );
				} );

				it( "allows the x-default hreflang value", function(){
					var page = parseWithBase(
						'<link rel="alternate" hreflang="x-default" href="https://example.test/">',
						"http://example.test/"
					);
					var alternates = variables.parser.getAlternateLinks( page );
					expect( alternates.len() ).toBe( 1 );
					expect( alternates[ 1 ].hreflang ).toBe( "x-default" );
				} );

				it( "skips an alternate with a missing hreflang or empty href", function(){
					var page = parseWithBase(
						'<link rel="alternate" href="https://example.test/no-lang.cfm">'
						& '<link rel="alternate" hreflang="" href="https://example.test/empty-lang.cfm">'
						& '<link rel="alternate" hreflang="es" href="">'
						& '<link rel="alternate" hreflang="fr" href="https://fr.example.test/">',
						"http://example.test/"
					);
					var alternates = variables.parser.getAlternateLinks( page );
					expect( alternates.len() ).toBe( 1 );
					expect( alternates[ 1 ].hreflang ).toBe( "fr" );
				} );

				it( "returns an exact duplicate alternate only once", function(){
					var page = parseWithBase(
						'<link rel="alternate" hreflang="es" href="https://es.example.test/">'
						& '<link rel="alternate" hreflang="es" href="https://es.example.test/">',
						"http://example.test/"
					);
					expect( variables.parser.getAlternateLinks( page ).len() ).toBe( 1 );
				} );

			} );

			describe( "getVideos()", function(){

				it( "builds a player_loc video from og:video with og:title, og:description, og:image", function(){
					var page = parseWithBase(
						'<html><head>'
						& '<meta property="og:video" content="https://player.other/embed/123">'
						& '<meta property="og:title" content="My Video Page">'
						& '<meta property="og:description" content="A page about a video.">'
						& '<meta property="og:image" content="https://example.test/thumb.jpg">'
						& '</head><body></body></html>',
						"http://example.test/"
					);
					var videos = variables.parser.getVideos( page );
					expect( videos.len() ).toBe( 1 );
					expect( videos[ 1 ].playerLoc ).toBe( "https://player.other/embed/123" );
					expect( videos[ 1 ].contentLoc ).toBe( "" );
					expect( videos[ 1 ].title ).toBe( "My Video Page" );
					expect( videos[ 1 ].description ).toBe( "A page about a video." );
					expect( videos[ 1 ].thumbnailLoc ).toBe( "https://example.test/thumb.jpg" );
				} );

				it( "prefers og:video:secure_url over og:video:url and og:video", function(){
					var page = parseWithBase(
						'<html><head>'
						& '<meta property="og:video" content="http://player.other/plain">'
						& '<meta property="og:video:url" content="http://player.other/url">'
						& '<meta property="og:video:secure_url" content="https://player.other/secure">'
						& '<meta property="og:title" content="T">'
						& '<meta property="og:description" content="D">'
						& '<meta property="og:image" content="https://example.test/thumb.jpg">'
						& '</head><body></body></html>',
						"http://example.test/"
					);
					var videos = variables.parser.getVideos( page );
					expect( videos.len() ).toBe( 1 );
					expect( videos[ 1 ].playerLoc ).toBe( "https://player.other/secure" );
				} );

				it( "builds a content_loc video from a video tag src with poster thumbnail", function(){
					var page = parseWithBase(
						'<html><head><title>Page Title</title>'
						& '<meta name="description" content="Page description.">'
						& '</head><body>'
						& '<video src="clip.mp4" poster="poster.jpg"></video>'
						& '</body></html>',
						"http://example.test/dir/"
					);
					var videos = variables.parser.getVideos( page );
					expect( videos.len() ).toBe( 1 );
					expect( videos[ 1 ].contentLoc ).toBe( "http://example.test/dir/clip.mp4" );
					expect( videos[ 1 ].playerLoc ).toBe( "" );
					expect( videos[ 1 ].thumbnailLoc ).toBe( "http://example.test/dir/poster.jpg" );
					expect( videos[ 1 ].title ).toBe( "Page Title" );
					expect( videos[ 1 ].description ).toBe( "Page description." );
				} );

				it( "reads the URL from a nested source child when the video tag has no src", function(){
					var page = parseWithBase(
						'<html><head><title>T</title>'
						& '<meta name="description" content="D">'
						& '</head><body>'
						& '<video poster="poster.jpg"><source src="clip.webm" type="video/webm"><source src="clip.mp4"></video>'
						& '</body></html>',
						"http://example.test/"
					);
					var videos = variables.parser.getVideos( page );
					expect( videos.len() ).toBe( 1 );
					expect( videos[ 1 ].contentLoc ).toBe( "http://example.test/clip.webm" );
				} );

				it( "falls back to the page title and meta description for required text fields", function(){
					// No og:title / og:description: the <title> tag and
					// <meta name=description> fill the required fields.
					var page = parseWithBase(
						'<html><head><title>Fallback Title</title>'
						& '<meta name="description" content="Fallback description.">'
						& '<meta property="og:video" content="https://player.other/embed/9">'
						& '<meta property="og:image" content="https://example.test/thumb.jpg">'
						& '</head><body></body></html>',
						"http://example.test/"
					);
					var videos = variables.parser.getVideos( page );
					expect( videos.len() ).toBe( 1 );
					expect( videos[ 1 ].title ).toBe( "Fallback Title" );
					expect( videos[ 1 ].description ).toBe( "Fallback description." );
				} );

				it( "falls back to og:image when a video tag has no poster", function(){
					var page = parseWithBase(
						'<html><head><title>T</title>'
						& '<meta name="description" content="D">'
						& '<meta property="og:image" content="https://example.test/og-thumb.jpg">'
						& '</head><body>'
						& '<video src="clip.mp4"></video>'
						& '</body></html>',
						"http://example.test/"
					);
					var videos = variables.parser.getVideos( page );
					expect( videos.len() ).toBe( 1 );
					expect( videos[ 1 ].thumbnailLoc ).toBe( "https://example.test/og-thumb.jpg" );
				} );

				it( "drops a video missing a thumbnail after fallbacks", function(){
					// No poster and no og:image: the thumbnail is required, so the
					// video is dropped.
					var page = parseWithBase(
						'<html><head><title>T</title>'
						& '<meta name="description" content="D">'
						& '</head><body>'
						& '<video src="clip.mp4"></video>'
						& '</body></html>',
						"http://example.test/"
					);
					expect( variables.parser.getVideos( page ).len() ).toBe( 0 );
				} );

				it( "drops a video element with no src and no source child", function(){
					var page = parseWithBase(
						'<html><head><title>T</title>'
						& '<meta name="description" content="D">'
						& '<meta property="og:image" content="https://example.test/thumb.jpg">'
						& '</head><body>'
						& '<video poster="poster.jpg"></video>'
						& '</body></html>',
						"http://example.test/"
					);
					expect( variables.parser.getVideos( page ).len() ).toBe( 0 );
				} );

				it( "returns a video declared via both og:video and a video tag only once", function(){
					// Both sources point at the same file, so only the OG entry
					// (collected first) survives the URL dedupe.
					var page = parseWithBase(
						'<html><head><title>T</title>'
						& '<meta name="description" content="D">'
						& '<meta property="og:video" content="http://example.test/same.mp4">'
						& '<meta property="og:image" content="https://example.test/thumb.jpg">'
						& '</head><body>'
						& '<video src="same.mp4" poster="poster.jpg"></video>'
						& '</body></html>',
						"http://example.test/"
					);
					var videos = variables.parser.getVideos( page );
					expect( videos.len() ).toBe( 1 );
					expect( videos[ 1 ].playerLoc ).toBe( "http://example.test/same.mp4" );
					expect( videos[ 1 ].contentLoc ).toBe( "" );
				} );

				it( "resolves relative video src and poster against the base URI", function(){
					var page = parseWithBase(
						'<html><head><title>T</title>'
						& '<meta name="description" content="D">'
						& '</head><body>'
						& '<video src="media/clip.mp4" poster="media/poster.jpg"></video>'
						& '</body></html>',
						"http://example.test/sub/"
					);
					var videos = variables.parser.getVideos( page );
					expect( videos[ 1 ].contentLoc ).toBe( "http://example.test/sub/media/clip.mp4" );
					expect( videos[ 1 ].thumbnailLoc ).toBe( "http://example.test/sub/media/poster.jpg" );
				} );

				it( "sets duration to 0 for og:video and video tag sources", function(){
					// Neither HTML source carries a duration, but every video
					// struct has the key so the generator can read it safely.
					var page = parseWithBase(
						'<html><head><title>T</title>'
						& '<meta name="description" content="D">'
						& '<meta property="og:video" content="https://player.other/embed/1">'
						& '<meta property="og:image" content="https://example.test/thumb.jpg">'
						& '</head><body>'
						& '<video src="clip.mp4" poster="poster.jpg"></video>'
						& '</body></html>',
						"http://example.test/"
					);
					var videos = variables.parser.getVideos( page );
					expect( videos.len() ).toBe( 2 );
					expect( videos[ 1 ].duration ).toBe( 0 );
					expect( videos[ 2 ].duration ).toBe( 0 );
				} );

				it( "reads a top-level JSON-LD VideoObject", function(){
					var page = parseWithBase(
						'<html><head><title>Page Title</title>'
						& '<script type="application/ld+json">'
						& '{ "@context": "https://schema.org", "@type": "VideoObject",'
						& ' "name": "JSON-LD Clip", "description": "Described in JSON-LD.",'
						& ' "thumbnailUrl": "https://example.test/jsonld-thumb.jpg",'
						& ' "contentUrl": "https://example.test/jsonld.mp4",'
						& ' "embedUrl": "https://player.other/embed/7" }'
						& '</script>'
						& '</head><body></body></html>',
						"http://example.test/"
					);
					var videos = variables.parser.getVideos( page );
					expect( videos.len() ).toBe( 1 );
					expect( videos[ 1 ].title ).toBe( "JSON-LD Clip" );
					expect( videos[ 1 ].description ).toBe( "Described in JSON-LD." );
					expect( videos[ 1 ].thumbnailLoc ).toBe( "https://example.test/jsonld-thumb.jpg" );
					expect( videos[ 1 ].contentLoc ).toBe( "https://example.test/jsonld.mp4" );
					expect( videos[ 1 ].playerLoc ).toBe( "https://player.other/embed/7" );
				} );

				it( "reads a VideoObject nested inside a @graph array", function(){
					var page = parseWithBase(
						'<html><head><title>T</title>'
						& '<script type="application/ld+json">'
						& '{ "@context": "https://schema.org", "@graph": ['
						& '{ "@type": "WebPage", "name": "Not a video" },'
						& '{ "@type": "VideoObject", "name": "Graph Clip",'
						& ' "description": "Inside a graph.",'
						& ' "thumbnailUrl": "https://example.test/g-thumb.jpg",'
						& ' "contentUrl": "https://example.test/graph.mp4" } ] }'
						& '</script>'
						& '</head><body></body></html>',
						"http://example.test/"
					);
					var videos = variables.parser.getVideos( page );
					expect( videos.len() ).toBe( 1 );
					expect( videos[ 1 ].title ).toBe( "Graph Clip" );
					expect( videos[ 1 ].contentLoc ).toBe( "https://example.test/graph.mp4" );
				} );

				it( "matches a VideoObject declared with the full schema.org IRI and an array type", function(){
					var page = parseWithBase(
						'<html><head><title>T</title>'
						& '<script type="application/ld+json">'
						& '{ "@type": [ "MediaObject", "http://schema.org/VideoObject" ],'
						& ' "name": "IRI Clip", "description": "Full IRI type.",'
						& ' "thumbnailUrl": "https://example.test/iri-thumb.jpg",'
						& ' "contentUrl": "https://example.test/iri.mp4" }'
						& '</script>'
						& '</head><body></body></html>',
						"http://example.test/"
					);
					var videos = variables.parser.getVideos( page );
					expect( videos.len() ).toBe( 1 );
					expect( videos[ 1 ].title ).toBe( "IRI Clip" );
				} );

				it( "skips a malformed JSON-LD block without throwing and still reads a valid one", function(){
					var page = parseWithBase(
						'<html><head><title>T</title>'
						& '<script type="application/ld+json">{ "@type": "VideoObject", oops </script>'
						& '<script type="application/ld+json">'
						& '{ "@type": "VideoObject", "name": "Good Clip", "description": "Valid block.",'
						& ' "thumbnailUrl": "https://example.test/ok-thumb.jpg",'
						& ' "contentUrl": "https://example.test/ok.mp4" }'
						& '</script>'
						& '</head><body></body></html>',
						"http://example.test/"
					);
					var videos = variables.parser.getVideos( page );
					expect( videos.len() ).toBe( 1 );
					expect( videos[ 1 ].title ).toBe( "Good Clip" );
				} );

				it( "takes the first entry when thumbnailUrl is an array and falls back to page text", function(){
					// No name or description on the VideoObject, so the page
					// <title> and meta description fill the required fields.
					var page = parseWithBase(
						'<html><head><title>Page Title</title>'
						& '<meta name="description" content="Page description.">'
						& '<script type="application/ld+json">'
						& '{ "@type": "VideoObject",'
						& ' "thumbnailUrl": [ "https://example.test/wide.jpg", "https://example.test/tall.jpg" ],'
						& ' "contentUrl": "https://example.test/array.mp4" }'
						& '</script>'
						& '</head><body></body></html>',
						"http://example.test/"
					);
					var videos = variables.parser.getVideos( page );
					expect( videos.len() ).toBe( 1 );
					expect( videos[ 1 ].thumbnailLoc ).toBe( "https://example.test/wide.jpg" );
					expect( videos[ 1 ].title ).toBe( "Page Title" );
					expect( videos[ 1 ].description ).toBe( "Page description." );
				} );

				it( "reads a thumbnail given as a nested ImageObject", function(){
					var page = parseWithBase(
						'<html><head><title>T</title>'
						& '<meta name="description" content="D">'
						& '<script type="application/ld+json">'
						& '{ "@type": "VideoObject",'
						& ' "thumbnailUrl": { "@type": "ImageObject", "url": "https://example.test/nested.jpg" },'
						& ' "contentUrl": "https://example.test/nested.mp4" }'
						& '</script>'
						& '</head><body></body></html>',
						"http://example.test/"
					);
					var videos = variables.parser.getVideos( page );
					expect( videos[ 1 ].thumbnailLoc ).toBe( "https://example.test/nested.jpg" );
				} );

				it( "resolves relative JSON-LD URLs against the base URI", function(){
					var page = parseWithBase(
						'<html><head><title>T</title>'
						& '<meta name="description" content="D">'
						& '<script type="application/ld+json">'
						& '{ "@type": "VideoObject", "thumbnailUrl": "thumb.jpg",'
						& ' "contentUrl": "media/clip.mp4" }'
						& '</script>'
						& '</head><body></body></html>',
						"http://example.test/sub/"
					);
					var videos = variables.parser.getVideos( page );
					expect( videos[ 1 ].contentLoc ).toBe( "http://example.test/sub/media/clip.mp4" );
					expect( videos[ 1 ].thumbnailLoc ).toBe( "http://example.test/sub/thumb.jpg" );
				} );

				it( "converts an ISO 8601 duration to whole seconds", function(){
					var durations = {
						"PT1M33S" : 93,
						"PT1H2M3S" : 3723,
						"PT45S" : 45,
						"P0DT2H" : 7200,
						"90" : 90
					};
					for ( var raw in durations ) {
						var page = parseWithBase(
							'<html><head><title>T</title>'
							& '<meta name="description" content="D">'
							& '<script type="application/ld+json">'
							& '{ "@type": "VideoObject", "thumbnailUrl": "https://example.test/t.jpg",'
							& ' "contentUrl": "https://example.test/d.mp4", "duration": "#raw#" }'
							& '</script>'
							& '</head><body></body></html>',
							"http://example.test/"
						);
						var videos = variables.parser.getVideos( page );
						expect( videos[ 1 ].duration ).toBe( durations[ raw ], "duration #raw#" );
					}
				} );

				it( "leaves duration at 0 when it cannot be read or is out of range", function(){
					// "P1M" is one month (no fixed length), "PT0S" is below
					// Google's minimum of 1, and "PT9H" is above its maximum of
					// 28800 seconds.
					for ( var raw in [ "banana", "P1M", "PT0S", "PT9H", "" ] ) {
						var page = parseWithBase(
							'<html><head><title>T</title>'
							& '<meta name="description" content="D">'
							& '<script type="application/ld+json">'
							& '{ "@type": "VideoObject", "thumbnailUrl": "https://example.test/t.jpg",'
							& ' "contentUrl": "https://example.test/d.mp4", "duration": "#raw#" }'
							& '</script>'
							& '</head><body></body></html>',
							"http://example.test/"
						);
						var videos = variables.parser.getVideos( page );
						expect( videos[ 1 ].duration ).toBe( 0, "duration #raw#" );
					}
				} );

				it( "keeps the JSON-LD entry when og:video names the same URL", function(){
					// JSON-LD is collected first, so its own name and
					// description win over the page-level fallbacks the OG
					// entry would have used.
					var page = parseWithBase(
						'<html><head><title>Page Title</title>'
						& '<meta name="description" content="Page description.">'
						& '<meta property="og:video" content="https://player.other/embed/7">'
						& '<meta property="og:image" content="https://example.test/og-thumb.jpg">'
						& '<script type="application/ld+json">'
						& '{ "@type": "VideoObject", "name": "JSON-LD Clip",'
						& ' "description": "Described in JSON-LD.",'
						& ' "thumbnailUrl": "https://example.test/jsonld-thumb.jpg",'
						& ' "embedUrl": "https://player.other/embed/7" }'
						& '</script>'
						& '</head><body></body></html>',
						"http://example.test/"
					);
					var videos = variables.parser.getVideos( page );
					expect( videos.len() ).toBe( 1 );
					expect( videos[ 1 ].title ).toBe( "JSON-LD Clip" );
					expect( videos[ 1 ].thumbnailLoc ).toBe( "https://example.test/jsonld-thumb.jpg" );
				} );

				it( "dedupes an og:video against a JSON-LD embedUrl even when the content URLs differ", function(){
					// The JSON-LD entry holds a media file and a player page.
					// Deduping on both of its URLs is what stops the OG tag,
					// which names only the player page, emitting a second time.
					var page = parseWithBase(
						'<html><head><title>T</title>'
						& '<meta name="description" content="D">'
						& '<meta property="og:video" content="https://player.other/embed/7">'
						& '<meta property="og:image" content="https://example.test/og-thumb.jpg">'
						& '<script type="application/ld+json">'
						& '{ "@type": "VideoObject", "name": "Both URLs", "description": "Media plus player.",'
						& ' "thumbnailUrl": "https://example.test/thumb.jpg",'
						& ' "contentUrl": "https://example.test/clip.mp4",'
						& ' "embedUrl": "https://player.other/embed/7" }'
						& '</script>'
						& '</head><body></body></html>',
						"http://example.test/"
					);
					var videos = variables.parser.getVideos( page );
					expect( videos.len() ).toBe( 1 );
					expect( videos[ 1 ].contentLoc ).toBe( "https://example.test/clip.mp4" );
					expect( videos[ 1 ].playerLoc ).toBe( "https://player.other/embed/7" );
				} );

				it( "drops a JSON-LD VideoObject with no content or embed URL", function(){
					var page = parseWithBase(
						'<html><head><title>T</title>'
						& '<meta name="description" content="D">'
						& '<script type="application/ld+json">'
						& '{ "@type": "VideoObject", "name": "No URL", "description": "Nothing to point at.",'
						& ' "thumbnailUrl": "https://example.test/thumb.jpg" }'
						& '</script>'
						& '</head><body></body></html>',
						"http://example.test/"
					);
					expect( variables.parser.getVideos( page ).len() ).toBe( 0 );
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

			describe( "isNoIndex()", function(){

				it( "detects a meta robots noindex tag", function(){
					var page = variables.parser.parseHtml(
						'<html><head><meta name="robots" content="noindex"></head></html>'
					);
					expect( variables.parser.isNoIndex( { headers : {} }, page ) ).toBeTrue();
				} );

				it( "detects noindex among comma-separated directives", function(){
					var page = variables.parser.parseHtml(
						'<html><head><meta name="robots" content="noindex, follow"></head></html>'
					);
					expect( variables.parser.isNoIndex( { headers : {} }, page ) ).toBeTrue();
				} );

				it( "treats meta robots none as noindex", function(){
					// "none" means noindex + nofollow.
					var page = variables.parser.parseHtml(
						'<html><head><meta name="robots" content="none"></head></html>'
					);
					expect( variables.parser.isNoIndex( { headers : {} }, page ) ).toBeTrue();
				} );

				it( "ignores a nofollow-only robots meta", function(){
					var page = variables.parser.parseHtml(
						'<html><head><meta name="robots" content="nofollow"></head></html>'
					);
					expect( variables.parser.isNoIndex( { headers : {} }, page ) ).toBeFalse();
				} );

				it( "detects an X-Robots-Tag noindex response header without a parsed page", function(){
					expect( variables.parser.isNoIndex( { headers : { "X-Robots-Tag" : "noindex" } } ) ).toBeTrue();
				} );

				it( "detects an agent-scoped X-Robots-Tag directive", function(){
					// "googlebot: noindex" is scoped to one crawler, but the page is
					// still left out of the sitemap for all of them on purpose.
					expect( variables.parser.isNoIndex( { headers : { "X-Robots-Tag" : "googlebot: noindex" } } ) ).toBeTrue();
				} );

				it( "returns false when neither header nor meta tag is present", function(){
					var page = variables.parser.parseHtml( "<html><head></head><body></body></html>" );
					expect( variables.parser.isNoIndex( { headers : {} }, page ) ).toBeFalse();
				} );

			} );

		} );
	}

}
