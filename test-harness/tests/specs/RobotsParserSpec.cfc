/**
 * Tests robots.txt rules, wildcards, longest-match precedence, user-agent
 * selection, query strings, and Crawl-delay without making HTTP requests.
 */
component extends="coldbox.system.testing.BaseTestCase" appMapping="root" {

	/**
	 * beforeAll
	 *
	 * Loads the shared dependencies and fixtures for these specs.
	 */
	function beforeAll(){
		super.beforeAll();
		setup();
	}

	/**
	 * afterAll
	 *
	 * Restores shared state changed by these specs.
	 */
	function afterAll(){
		super.afterAll();
	}

	// Builds a fresh parser fed with the given robots.txt content and user agent.
	// RobotsParser is transient, so getInstance() returns a new one each call.
	/**
	 * parserFor
	 *
	 * Returns a RobotsParser loaded with the given rules.
	 */
	private any function parserFor( required string content, string userAgent = "testbot" ){
		var p = getInstance( "RobotsParser@sitemap-spider" );
		p.parse( arguments.content, arguments.userAgent );
		return p;
	}

	/**
	 * run
	 *
	 * Defines the RobotsParserSpec examples.
	 */
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

				it( "does not let a trailing slash rule block its slashless sibling", function(){
					var p = parserFor( "User-agent: *#chr(10)#Disallow: /admin/" );
					expect( p.isPathAllowed( "/admin/users" ) ).toBeFalse();
					expect( p.isPathAllowed( "/admin" ) ).toBeTrue();
				} );

				it( "treats a slashless rule as a broad prefix match", function(){
					var p = parserFor( "User-agent: *#chr(10)#Disallow: /admin" );
					expect( p.isPathAllowed( "/admin" ) ).toBeFalse();
					expect( p.isPathAllowed( "/admin/users" ) ).toBeFalse();
					expect( p.isPathAllowed( "/administrator" ) ).toBeFalse();
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

				// Match the group to the exact product token, ignoring case.

				it( "does not match a group token that is only a substring of the product token", function(){
					// "spider" does not match "sitemap-spider", so "*" applies.
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

				// Rules can match the query string passed with the path.

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
