/**
 * Unit specs for RobotsParser.cfc.
 *
 * RobotsParser is pure (no HTTP): parse() reads robots.txt text, and
 * isPathAllowed()/getCrawlDelay() answer questions about the active user-agent
 * group. Every spec news up a fresh RobotsParser and feeds it literal robots.txt
 * content, so no server or fixture file is needed.
 *
 * Covers the task 07 behavior: Disallow/Allow prefix + "*"/"$" wildcards with
 * longest-match precedence (tie -> Allow), user-agent group selection, and
 * Crawl-delay parsing.
 *
 * Task 17 adds RFC 9309 user-agent selection (product-token equality, not a
 * substring of the whole user agent) and query-string matching in isPathAllowed.
 *
 * Local run recipe:
 *   1. box server start serverConfigFile=server-adobe@2023.json
 *   2. box testbox run runner="http://localhost:61002/tests/runner.cfm" bundles="tests.specs.RobotsParserSpec"
 */
component extends="coldbox.system.testing.BaseTestCase" appMapping="root" {

	function beforeAll(){
		super.beforeAll();
		setup();
	}

	function afterAll(){
		super.afterAll();
	}

	// Builds a fresh parser fed with the given robots.txt content and user agent.
	// RobotsParser is transient, so getInstance() returns a new one each call.
	private any function parserFor( required string content, string userAgent = "testbot" ){
		var p = getInstance( "RobotsParser@sitemap-spider" );
		p.parse( arguments.content, arguments.userAgent );
		return p;
	}

	function run(){
		describe( "RobotsParser", function(){

			describe( "isPathAllowed() Disallow matching", function(){

				it( "disallows a path under a Disallow prefix", function(){
					var p = parserFor( "User-agent: *#chr(10)#Disallow: /disallow.cfm" );
					expect( p.isPathAllowed( "/disallow.cfm" ) ).toBeFalse();
				} );

				it( "allows a path that no rule matches", function(){
					var p = parserFor( "User-agent: *#chr(10)#Disallow: /disallow.cfm" );
					expect( p.isPathAllowed( "/contact.cfm" ) ).toBeTrue();
				} );

				it( "allows everything when Disallow has an empty value", function(){
					var p = parserFor( "User-agent: *#chr(10)#Disallow:" );
					expect( p.isPathAllowed( "/anything.cfm" ) ).toBeTrue();
				} );

				it( "allows everything with no robots content", function(){
					var p = parserFor( "" );
					expect( p.isPathAllowed( "/anything.cfm" ) ).toBeTrue();
				} );

			} );

			describe( "isPathAllowed() Allow / longest-match precedence", function(){

				it( "lets a longer Allow override a broader Disallow", function(){
					var content = "User-agent: *#chr(10)#Disallow: /a/#chr(10)#Allow: /a/keep.cfm";
					var p = parserFor( content );
					expect( p.isPathAllowed( "/a/keep.cfm" ) ).toBeTrue();
					expect( p.isPathAllowed( "/a/drop.cfm" ) ).toBeFalse();
				} );

				it( "resolves an equal-length tie in favor of Allow", function(){
					var content = "User-agent: *#chr(10)#Disallow: /page.cfm#chr(10)#Allow: /page.cfm";
					var p = parserFor( content );
					expect( p.isPathAllowed( "/page.cfm" ) ).toBeTrue();
				} );

			} );

			describe( "isPathAllowed() wildcards", function(){

				it( "matches a '*' wildcard in the middle of a pattern", function(){
					var p = parserFor( "User-agent: *#chr(10)#Disallow: /private/*/secret.cfm" );
					expect( p.isPathAllowed( "/private/a/secret.cfm" ) ).toBeFalse();
					expect( p.isPathAllowed( "/private/a/public.cfm" ) ).toBeTrue();
				} );

				it( "anchors the end with '$'", function(){
					var p = parserFor( "User-agent: *#chr(10)#Disallow: /report.pdf$" );
					// Exact end matches; a longer path does not.
					expect( p.isPathAllowed( "/report.pdf" ) ).toBeFalse();
					expect( p.isPathAllowed( "/report.pdf.bak" ) ).toBeTrue();
				} );

			} );

			describe( "user-agent group selection", function(){

				it( "prefers a specific group over the '*' group", function(){
					var content = "User-agent: *#chr(10)#Disallow: /#chr(10)##chr(10)#User-agent: testbot#chr(10)#Disallow: /admin.cfm";
					// testbot's own group only blocks /admin.cfm, so /home.cfm is allowed.
					var p = parserFor( content, "testbot" );
					expect( p.isPathAllowed( "/home.cfm" ) ).toBeTrue();
					expect( p.isPathAllowed( "/admin.cfm" ) ).toBeFalse();
				} );

				it( "falls back to the '*' group when no specific group matches", function(){
					var content = "User-agent: *#chr(10)#Disallow: /blocked.cfm#chr(10)##chr(10)#User-agent: googlebot#chr(10)#Disallow: /";
					var p = parserFor( content, "testbot" );
					expect( p.isPathAllowed( "/blocked.cfm" ) ).toBeFalse();
					expect( p.isPathAllowed( "/other.cfm" ) ).toBeTrue();
				} );

				// Task 17 RFC 9309 §2.2.1: match the group token against the
				// crawler's product token by case-insensitive equality, not a
				// substring of the whole user agent.

				it( "does not match a group token that is only a substring of the product token", function(){
					// Group "spider" must NOT capture crawler "sitemap-spider"; it
					// falls back to the "*" group instead.
					var content = "User-agent: *#chr(10)#Disallow: /star.cfm#chr(10)##chr(10)#User-agent: spider#chr(10)#Disallow: /spider.cfm";
					var p = parserFor( content, "sitemap-spider" );
					expect( p.isPathAllowed( "/star.cfm" ) ).toBeFalse();   // "*" group applies
					expect( p.isPathAllowed( "/spider.cfm" ) ).toBeTrue();  // "spider" group ignored
				} );

				it( "matches the group token case-insensitively against the exact product token", function(){
					var content = "User-agent: SiteMap-Spider#chr(10)#Disallow: /admin.cfm";
					var p = parserFor( content, "sitemap-spider" );
					expect( p.isPathAllowed( "/admin.cfm" ) ).toBeFalse();
				} );

				it( "reduces a user agent with a /version suffix to its product token", function(){
					var content = "User-agent: mybot#chr(10)#Disallow: /admin.cfm";
					var p = parserFor( content, "mybot/1.0 (+http://example.test/bot)" );
					expect( p.isPathAllowed( "/admin.cfm" ) ).toBeFalse();
				} );

			} );

			describe( "isPathAllowed() query-string matching", function(){

				// Task 17: the caller may pass "path?query", so a rule that targets
				// the query string can match.

				it( "blocks a path whose query matches a query pattern", function(){
					var p = parserFor( "User-agent: *#chr(10)#Disallow: /*?sort=" );
					expect( p.isPathAllowed( "/list?sort=asc" ) ).toBeFalse();
					expect( p.isPathAllowed( "/list?page=2" ) ).toBeTrue();
				} );

				it( "still blocks path+query under a plain path prefix", function(){
					var p = parserFor( "User-agent: *#chr(10)#Disallow: /private" );
					expect( p.isPathAllowed( "/private/page.cfm?x=1" ) ).toBeFalse();
				} );

			} );

			describe( "getCrawlDelay()", function(){

				it( "returns the parsed Crawl-delay", function(){
					var p = parserFor( "User-agent: *#chr(10)#Crawl-delay: 2" );
					expect( p.getCrawlDelay() ).toBe( 2 );
				} );

				it( "returns 0 when no Crawl-delay is declared", function(){
					var p = parserFor( "User-agent: *#chr(10)#Disallow: /x.cfm" );
					expect( p.getCrawlDelay() ).toBe( 0 );
				} );

			} );

			describe( "ignored lines", function(){

				it( "ignores Sitemap and comment lines", function(){
					var content = "## a comment#chr(10)#User-agent: *#chr(10)#Sitemap: https://example.test/sitemap.xml#chr(10)#Disallow: /x.cfm";
					var p = parserFor( content );
					// Parsing still works: the Disallow is honored and Sitemap is a no-op.
					expect( p.isPathAllowed( "/x.cfm" ) ).toBeFalse();
					expect( p.isPathAllowed( "/y.cfm" ) ).toBeTrue();
				} );

			} );

		} );
	}

}
