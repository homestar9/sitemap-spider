/**
 * Unit specs for SitemapGenerator.cfc.
 *
 * Covers generate() output shape and escaping, and the saveToFile() round-trip.
 * The generator has no injected dependencies, so no mocking is needed. pages is
 * an array of page structs (each { url, lastModified, priority[, images] }), built
 * with the page() helper below.
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

	// Builds one page struct in the array shape generate()/generateSet() take. The
	// images key is added only when passed, so a page without images stays
	// image-free (the generator guards on the key).
	private struct function page(
		required string url,
		required numeric priority,
		any lastModified = "",
		array images
	){
		var p = { url : arguments.url, lastModified : arguments.lastModified, priority : arguments.priority };
		if ( !isNull( arguments.images ) ){
			p.images = arguments.images;
		}
		return p;
	}

	function run(){
		describe( "SitemapGenerator", function(){

			describe( "generate()", function(){

				it( "produces XML that parses into a urlset with one url per page", function(){
					var pages = [
						page( "http://example.test/a.cfm", 0.9 ),
						page( "http://example.test/b.cfm", 0.8 )
					];

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
					var pages  = [ page( rawUrl, 0.5 ) ];

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
					var withDate = variables.generator.generate( [
						page( "http://example.test/dated.cfm", 0.5, "2026-07-20" )
					] );
					var withoutDate = variables.generator.generate( [
						page( "http://example.test/undated.cfm", 0.5 )
					] );

					expect( withDate ).toInclude( "<lastmod>2026-07-20</lastmod>" );
					expect( withoutDate.findNoCase( "<lastmod>" ) ).toBe( 0 );
				} );

				it( "formats a real date object as W3C date-only (yyyy-mm-dd)", function(){
					// A parsed date carries a time-of-day; <lastmod> must drop it and
					// keep the zero-padded YYYY-MM-DD form.
					var when = createDateTime( 2026, 3, 5, 14, 30, 0 );
					var xml  = variables.generator.generate( [
						page( "http://example.test/a.cfm", 0.5, when )
					] );
					expect( xml ).toInclude( "<lastmod>2026-03-05</lastmod>" );
				} );

				it( "renders priority with one decimal place", function(){
					var xml = variables.generator.generate( [
						page( "http://example.test/a.cfm", 1.0 )
					] );
					expect( xml ).toInclude( "<priority>1.0</priority>" );
				} );

				it( "always renders priority", function(){
					var xml = variables.generator.generate( [
						page( "http://example.test/a.cfm", 0.5 )
					] );
					expect( xml ).toInclude( "<priority>0.5</priority>" );
				} );

				it( "emits a full W3C timestamp when lastModFormat is datetime", function(){
					// A real date object carries a time-of-day. In datetime mode the
					// <lastmod> keeps it and appends the server's local offset, e.g.
					// 2026-03-05T14:30:00+00:00.
					var when = createDateTime( 2026, 3, 5, 14, 30, 0 );
					var xml  = variables.generator.generate(
						pages         = [ page( "http://example.test/a.cfm", 0.5, when ) ],
						lastModFormat = "datetime"
					);
					// Match the W3C datetime shape without hard-coding the offset,
					// which depends on the test server's timezone.
					expect( xml ).toMatch( "<lastmod>2026-03-05T14:30:00[+-]\d\d:\d\d</lastmod>" );
				} );

				it( "formats a plain date string in datetime mode as midnight", function(){
					// The generator also receives date strings (e.g. from tests). A
					// date-only string has no time, so it renders at 00:00:00.
					var xml = variables.generator.generate(
						pages         = [ page( "http://example.test/a.cfm", 0.5, "2026-07-20" ) ],
						lastModFormat = "datetime"
					);
					expect( xml ).toMatch( "<lastmod>2026-07-20T00:00:00[+-]\d\d:\d\d</lastmod>" );
				} );

				it( "still emits date-only lastmod by default", function(){
					// Default (no lastModFormat) keeps the date-only W3C form.
					var xml = variables.generator.generate( [
						page( "http://example.test/a.cfm", 0.5, "2026-07-20" )
					] );
					expect( xml ).toInclude( "<lastmod>2026-07-20</lastmod>" );
					expect( xml ).notToMatch( "T\d\d:\d\d:\d\d" );
				} );

				it( "adds the image namespace and <image:image> entries when includeImages is on", function(){
					var pages = [
						page(
							url    = "http://example.test/a.cfm",
							priority = 0.5,
							images = [ "http://example.test/img/1.jpg", "http://cdn.other/2.png" ]
						)
					];
					var xml = variables.generator.generate( pages = pages, includeImages = true );

					expect( xml ).toInclude( 'xmlns:image="http://www.google.com/schemas/sitemap-image/1.1"' );
					expect( xml ).toInclude( "<image:image><image:loc>http://example.test/img/1.jpg</image:loc></image:image>" );
					expect( xml ).toInclude( "<image:loc>http://cdn.other/2.png</image:loc>" );
					// Valid XML with the namespace declared.
					var doc = xmlParse( xml );
					expect( doc.xmlRoot.xmlName ).toBe( "urlset" );
				} );

				it( "leaves images out and keeps output byte-identical when includeImages is off", function(){
					// A page that happens to carry an images array must produce the
					// exact same XML as one without it when includeImages is off.
					var withImages = variables.generator.generate( [
						page( url = "http://example.test/a.cfm", priority = 0.5, images = [ "http://example.test/x.jpg" ] )
					] );
					var withoutImages = variables.generator.generate( [
						page( "http://example.test/a.cfm", 0.5 )
					] );
					expect( withImages ).toBe( withoutImages );
					expect( withImages.findNoCase( "image:" ) ).toBe( 0 );
				} );

			} );

			describe( "generateSet()", function(){

				it( "returns a single urlset when under the limits", function(){
					var pages = [
						page( "http://example.test/a.cfm", 0.9 ),
						page( "http://example.test/b.cfm", 0.8 )
					];

					var out = variables.generator.generateSet( pages = pages, maxUrls = 50000 );

					expect( out.type ).toBe( "single" );
					expect( out.sitemaps ).toBeEmpty();
					var doc = xmlParse( out.xml );
					expect( doc.xmlRoot.xmlName ).toBe( "urlset" );
					expect( doc.xmlRoot.xmlChildren.len() ).toBe( 2 );
				} );

				it( "single output matches generate() byte-for-byte", function(){
					var pages = [
						page( "http://example.test/a.cfm", 0.9, "2026-07-20" ),
						page( "http://example.test/b.cfm", 0.8 )
					];

					var out = variables.generator.generateSet( pages = pages );

					expect( out.xml ).toBe( variables.generator.generate( pages ) );
				} );

				it( "splits into an index plus child sitemaps when over maxUrls", function(){
					var pages = [
						page( "http://example.test/1.cfm", 0.5 ),
						page( "http://example.test/2.cfm", 0.5 ),
						page( "http://example.test/3.cfm", 0.5 ),
						page( "http://example.test/4.cfm", 0.5 ),
						page( "http://example.test/5.cfm", 0.5 )
					];

					var out = variables.generator.generateSet(
						pages         = pages,
						publicBaseUrl = "https://example.test/",
						maxUrls       = 2
					);

					// 5 URLs at 2 per file -> 3 child sitemaps.
					expect( out.type ).toBe( "index" );
					expect( out.sitemaps.len() ).toBe( 3 );

					// The index parses to a sitemapindex with 3 <sitemap> entries
					// whose <loc>s are the absolute child URLs.
					var indexDoc = xmlParse( out.xml );
					expect( indexDoc.xmlRoot.xmlName ).toBe( "sitemapindex" );
					expect( indexDoc.xmlRoot.xmlChildren.len() ).toBe( 3 );
					expect( out.xml ).toInclude( "<loc>https://example.test/sitemap-1.xml</loc>" );
					expect( out.xml ).toInclude( "<loc>https://example.test/sitemap-3.xml</loc>" );

					// Each child parses to a urlset; the total URL count is 5 and no
					// child exceeds the limit.
					var totalUrls = 0;
					for ( var child in out.sitemaps ) {
						var childDoc = xmlParse( child.xml );
						expect( childDoc.xmlRoot.xmlName ).toBe( "urlset" );
						expect( child.urlCount ).toBeLTE( 2 );
						totalUrls += child.urlCount;
					}
					expect( totalUrls ).toBe( 5 );
				} );

				it( "derives child filenames from primaryFilename", function(){
					var pages = [
						page( "http://example.test/1.cfm", 0.5 ),
						page( "http://example.test/2.cfm", 0.5 ),
						page( "http://example.test/3.cfm", 0.5 )
					];

					var out = variables.generator.generateSet(
						pages           = pages,
						publicBaseUrl   = "https://example.test/",
						primaryFilename = "foo.xml",
						maxUrls         = 2
					);

					expect( out.sitemaps[ 1 ].filename ).toBe( "foo-1.xml" );
					expect( out.sitemaps[ 2 ].filename ).toBe( "foo-2.xml" );
					expect( out.xml ).toInclude( "<loc>https://example.test/foo-1.xml</loc>" );
				} );

				it( "splits by byte size when maxBytes is small", function(){
					var pages = [
						page( "http://example.test/1.cfm", 0.5 ),
						page( "http://example.test/2.cfm", 0.5 ),
						page( "http://example.test/3.cfm", 0.5 )
					];

					// A tiny byte budget forces one URL per file even though the URL
					// count is well under maxUrls.
					var out = variables.generator.generateSet(
						pages         = pages,
						publicBaseUrl = "https://example.test/",
						maxUrls       = 50000,
						maxBytes      = 200
					);

					expect( out.type ).toBe( "index" );
					expect( out.sitemaps.len() ).toBe( 3 );
				} );

				it( "sets the index lastmod to the newest page date in each chunk", function(){
					var pages = [
						page( "http://example.test/1.cfm", 0.5, "2026-01-10" ),
						page( "http://example.test/2.cfm", 0.5, "2026-03-25" )
					];

					var out = variables.generator.generateSet(
						pages         = pages,
						publicBaseUrl = "https://example.test/",
						maxUrls       = 50000,
						maxBytes      = 200 // force one URL per file
					);

					expect( out.sitemaps[ 1 ].lastmod ).toBe( "2026-01-10" );
					expect( out.sitemaps[ 2 ].lastmod ).toBe( "2026-03-25" );
					expect( out.xml ).toInclude( "<lastmod>2026-03-25</lastmod>" );
				} );

				it( "gives child filenames and index <loc> a .gz suffix when gzip is on", function(){
					var pages = [
						page( "http://example.test/1.cfm", 0.5 ),
						page( "http://example.test/2.cfm", 0.5 ),
						page( "http://example.test/3.cfm", 0.5 )
					];

					var out = variables.generator.generateSet(
						pages         = pages,
						publicBaseUrl = "https://example.test/",
						maxUrls       = 2,
						gzip          = true
					);

					// Child names carry .gz after the .xml extension...
					expect( out.sitemaps[ 1 ].filename ).toBe( "sitemap-1.xml.gz" );
					expect( out.sitemaps[ 2 ].filename ).toBe( "sitemap-2.xml.gz" );
					// ...and the index <loc> references the same .gz names.
					expect( out.xml ).toInclude( "<loc>https://example.test/sitemap-1.xml.gz</loc>" );
					// The child xml itself stays uncompressed text and parses.
					var childDoc = xmlParse( out.sitemaps[ 1 ].xml );
					expect( childDoc.xmlRoot.xmlName ).toBe( "urlset" );
				} );

			} );

			describe( "saveToFile()", function(){

				it( "writes the XML and reads back exactly what was written", function(){
					var xml = variables.generator.generate( [
						page( "http://example.test/a.cfm", 0.5 )
					] );
					variables.tempFile = getTempDirectory() & "sitemap-generator-spec.xml";

					variables.generator.saveToFile( xml, variables.tempFile );

					expect( fileExists( variables.tempFile ) ).toBeTrue();
					expect( fileRead( variables.tempFile ) ).toBe( xml );
				} );

				it( "creates the parent directory when it does not exist", function(){
					var xml = variables.generator.generate( [
						page( "http://example.test/a.cfm", 0.5 )
					] );
					// A subdirectory that does not exist yet; saveToFile must create it.
					variables.tempDir = getTempDirectory() & "sitemap-generator-spec-dir-" & getTickCount() & "/";
					var target        = variables.tempDir & "nested/sitemap.xml";

					variables.generator.saveToFile( xml, target );

					expect( fileExists( target ) ).toBeTrue();
					expect( fileRead( target ) ).toBe( xml );
				} );

				it( "writes gzip-compressed bytes that gunzip back to the exact XML", function(){
					var xml = variables.generator.generate( [
						page( "http://example.test/a.cfm", 0.5 )
					] );
					variables.tempFile = getTempDirectory() & "sitemap-generator-spec-" & getTickCount() & ".xml.gz";

					variables.generator.saveToFile( xml, variables.tempFile, true );

					expect( fileExists( variables.tempFile ) ).toBeTrue();
					// Gunzip the file and confirm it matches the original XML.
					var fis  = createObject( "java", "java.io.FileInputStream" ).init( variables.tempFile );
					var gzis = createObject( "java", "java.util.zip.GZIPInputStream" ).init( fis );
					var bytes = gzis.readAllBytes();
					gzis.close();
					var roundTripped = charsetEncode( bytes, "utf-8" );
					expect( roundTripped ).toBe( xml );
				} );

			} );

		} );
	}

}
