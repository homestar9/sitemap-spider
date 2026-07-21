/**
 * Unit specs for SitemapGenerator.cfc.
 *
 * Covers generate() output shape and escaping, and the saveToFile() round-trip.
 * The generator has no injected dependencies, so no mocking is needed. Each page
 * struct is built by hand as { "<url>" : { lastModified, priority } }.
 *
 * Local run recipe:
 *   1. box server start serverConfigFile=server-adobe@2023.json
 *   2. box testbox run runner="http://localhost:61002/tests/runner.cfm" bundles="tests.specs.SitemapGeneratorSpec"
 */
component extends="coldbox.system.testing.BaseTestCase" appMapping="root" {

	function beforeAll(){
		super.beforeAll();
		setup();

		variables.generator = getInstance( "SitemapGenerator@sitemap-spider" );
		variables.tempFile  = "";
		variables.tempDir   = "";
	}

	function afterAll(){
		// Remove the file saveToFile() wrote, if the test left one behind.
		if ( len( variables.tempFile ) && fileExists( variables.tempFile ) ) {
			fileDelete( variables.tempFile );
		}
		// Remove the directory saveToFile() created for the directory-creation test.
		if ( len( variables.tempDir ) && directoryExists( variables.tempDir ) ) {
			directoryDelete( variables.tempDir, true );
		}
		super.afterAll();
	}

	function run(){
		describe( "SitemapGenerator", function(){

			describe( "generate()", function(){

				it( "produces XML that parses into a urlset with one url per page", function(){
					var pages = {
						"http://example.test/a.cfm" : { lastModified : "", priority : 0.9 },
						"http://example.test/b.cfm" : { lastModified : "", priority : 0.8 }
					};

					var xml = variables.generator.generate( pages );
					var doc = xmlParse( xml );

					expect( doc.xmlRoot.xmlName ).toBe( "urlset" );
					expect( doc.xmlRoot.xmlNsURI ).toBe( "http://www.sitemaps.org/schemas/sitemap/0.9" );
					// One <url> element per page.
					expect( doc.xmlRoot.xmlChildren.len() ).toBe( 2 );
					expect( xml ).toInclude( "<loc>http://example.test/a.cfm</loc>" );
				} );

				it( "escapes an ampersand in a loc value so the XML stays valid", function(){
					var rawUrl = "http://example.test/?a=1&b=2";
					var pages  = { "#rawUrl#" : { lastModified : "", priority : 0.5 } };

					var xml = variables.generator.generate( pages );

					// The raw string carries the escaped entity...
					expect( xml ).toInclude( "&amp;" );
					// ...and it parses back to the original URL (would throw if unescaped).
					var doc = xmlParse( xml );
					// Children of <url> are <loc> then <priority> (no lastmod here).
					var loc = doc.xmlRoot.xmlChildren[ 1 ].xmlChildren[ 1 ];
					expect( loc.xmlName ).toBe( "loc" );
					expect( loc.xmlText ).toBe( rawUrl );
				} );

				it( "omits lastmod when it is empty and includes it when set", function(){
					var withDate = variables.generator.generate( {
						"http://example.test/dated.cfm" : { lastModified : "2026-07-20", priority : 0.5 }
					} );
					var withoutDate = variables.generator.generate( {
						"http://example.test/undated.cfm" : { lastModified : "", priority : 0.5 }
					} );

					expect( withDate ).toInclude( "<lastmod>2026-07-20</lastmod>" );
					expect( withoutDate.findNoCase( "<lastmod>" ) ).toBe( 0 );
				} );

				it( "formats a real date object as W3C date-only (yyyy-mm-dd)", function(){
					// A parsed date carries a time-of-day; <lastmod> must drop it and
					// keep the zero-padded YYYY-MM-DD form.
					var when = createDateTime( 2026, 3, 5, 14, 30, 0 );
					var xml  = variables.generator.generate( {
						"http://example.test/a.cfm" : { lastModified : when, priority : 0.5 }
					} );
					expect( xml ).toInclude( "<lastmod>2026-03-05</lastmod>" );
				} );

				it( "renders priority with one decimal place", function(){
					var xml = variables.generator.generate( {
						"http://example.test/a.cfm" : { lastModified : "", priority : 1.0 }
					} );
					expect( xml ).toInclude( "<priority>1.0</priority>" );
				} );

				it( "always renders priority", function(){
					var xml = variables.generator.generate( {
						"http://example.test/a.cfm" : { lastModified : "", priority : 0.5 }
					} );
					expect( xml ).toInclude( "<priority>0.5</priority>" );
				} );

			} );

			describe( "saveToFile()", function(){

				it( "writes the XML and reads back exactly what was written", function(){
					var xml = variables.generator.generate( {
						"http://example.test/a.cfm" : { lastModified : "", priority : 0.5 }
					} );
					variables.tempFile = getTempDirectory() & "sitemap-generator-spec.xml";

					variables.generator.saveToFile( xml, variables.tempFile );

					expect( fileExists( variables.tempFile ) ).toBeTrue();
					expect( fileRead( variables.tempFile ) ).toBe( xml );
				} );

				it( "creates the parent directory when it does not exist", function(){
					var xml = variables.generator.generate( {
						"http://example.test/a.cfm" : { lastModified : "", priority : 0.5 }
					} );
					// A subdirectory that does not exist yet; saveToFile must create it.
					variables.tempDir = getTempDirectory() & "sitemap-generator-spec-dir-" & getTickCount() & "/";
					var target        = variables.tempDir & "nested/sitemap.xml";

					variables.generator.saveToFile( xml, target );

					expect( fileExists( target ) ).toBeTrue();
					expect( fileRead( target ) ).toBe( xml );
				} );

			} );

		} );
	}

}
