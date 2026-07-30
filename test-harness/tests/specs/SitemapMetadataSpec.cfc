/**
 * Tests crawl statistics and JSON metadata, including custom paths, URL details,
 * gzip output, and readMetadata().
 */
component extends="coldbox.system.testing.BaseTestCase" appMapping="root" {

	variables.serverRoot = "http#( CGI.HTTPS == "on" ? 's' : '' )#://" & CGI.HTTP_HOST & "/";

	/**
	 * beforeAll
	 *
	 * Loads the shared dependencies and fixtures for these specs.
	 */
	function beforeAll(){
		super.beforeAll();
		setup();

		variables.appRoot = variables.serverRoot & "tests/resources/sample-site/";
		variables.tempDir = getTempDirectory() & "sitemap-spider-metadata-spec/";
		variables.service = getInstance( "sitemapService@sitemap-spider" );

		// Collect statistics without saving a sitemap.
		variables.baseline = variables.service.create( variables.appRoot );

		// Save a sitemap with metadata disabled.
		variables.plainFilePath = variables.tempDir & "plain/sitemap.xml";
		variables.plainResult   = variables.service.create(
			url      = variables.appRoot,
			filePath = variables.plainFilePath
		);

		// Save metadata beside the sitemap.
		variables.metaFilePath = variables.tempDir & "meta/sitemap.xml";
		variables.metaResult   = variables.service.create(
			url           = variables.appRoot,
			filePath      = variables.metaFilePath,
			writeMetadata = true
		);
	}

	/**
	 * afterAll
	 *
	 * Restores shared state changed by these specs.
	 */
	function afterAll(){
		if ( directoryExists( variables.tempDir ) ) {
			directoryDelete( variables.tempDir, true );
		}
		super.afterAll();
	}

	/**
	 * run
	 *
	 * Defines the SitemapMetadataSpec examples.
	 */
	function run(){
		describe( "create() stats struct", function(){

			it( "returns a stats struct with pre-computed counts", function(){
				var stats = variables.baseline.stats;
				expect( stats ).toBeStruct();
				expect( stats ).toHaveKey( "generatedAt,durationMs,urlCount,sitemapCount,type,badUrlCount,ignoredCount,redirectCount" );
				expect( stats.urlCount ).toBe( variables.baseline.pages.len() );
				expect( stats.badUrlCount ).toBe( structCount( variables.baseline.badUrls ) );
				expect( stats.ignoredCount ).toBe( variables.baseline.ignored.len() );
				expect( stats.redirectCount ).toBe( variables.baseline.redirects.len() );
				expect( stats.type ).toBe( variables.baseline.type );
				expect( stats.sitemapCount ).toBe( variables.baseline.sitemapCount );
				expect( stats.durationMs ).toBe( variables.baseline.duration );
			} );

			it( "writes generatedAt as a parseable ISO-8601 timestamp with offset", function(){
				// e.g. "2026-07-29T14:03:22-07:00". Asserting the shape (not the
				// value) keeps the spec timezone-independent.
				expect( variables.baseline.stats.generatedAt )
					.toMatch( "^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$" );
			} );

		} );

		describe( "metadata sidecar", function(){

			it( "does not write a metadata file by default", function(){
				expect( variables.plainResult.saved ).toBeTrue();
				expect( variables.plainResult.metadataSaved ).toBeFalse();
				expect( variables.plainResult.metadataPath ).toBe( "" );
				expect( fileExists( variables.plainFilePath & ".meta.json" ) ).toBeFalse();
			} );

			it( "writes the sidecar next to the sitemap when writeMetadata is true", function(){
				expect( variables.metaResult.metadataSaved ).toBeTrue();
				expect( variables.metaResult.metadataPath ).toBe( variables.metaFilePath & ".meta.json" );
				expect( fileExists( variables.metaResult.metadataPath ) ).toBeTrue();

				var metadata = deserializeJSON( fileRead( variables.metaResult.metadataPath ) );
				expect( metadata.schemaVersion ).toBe( 1 );
				// In the dev harness the version is an unstamped build placeholder,
				// so only assert it is a non-empty string.
				expect( metadata.moduleVersion ).toBeString();
				expect( len( metadata.moduleVersion ) ).toBeGT( 0 );
				expect( metadata.stats.urlCount ).toBe( variables.metaResult.stats.urlCount );
				expect( metadata.stats.generatedAt ).toBe( variables.metaResult.stats.generatedAt );
				expect( metadata.filePath ).toBe( variables.metaFilePath );
				expect( metadata.options ).toHaveKey( "url,includeImages,includeHreflang,includeVideos,runAsync,maxPages,maxDepth,gzipOutput,lastModFormat,excludePattern,browserDsl,userAgent" );
				expect( metadata.options.url ).toBe( variables.appRoot );
			} );

			it( "leaves URL details out of the sidecar by default", function(){
				var metadata = deserializeJSON( fileRead( variables.metaResult.metadataPath ) );
				expect( metadata ).notToHaveKey( "badUrls" );
				expect( metadata ).notToHaveKey( "ignored" );
				// The counts are still there via stats.
				expect( metadata.stats.badUrlCount ).toBeGT( 0 );
			} );

			it( "writes the sidecar to a caller-specified metadataPath", function(){
				var settings       = getInstance( "coldbox:moduleSettings:sitemap-spider" );
				var savedPath      = settings.metadataPath;
				var configuredPath = variables.tempDir & "configured/unused.meta.json";
				var customPath     = variables.tempDir & "private/stats.meta.json";
				settings.metadataPath = configuredPath;
				try {
					var result = variables.service.create(
						url           = variables.appRoot,
						filePath      = variables.tempDir & "custom/sitemap.xml",
						writeMetadata = true,
						metadataPath  = customPath
					);
					expect( result.metadataSaved ).toBeTrue();
					expect( result.metadataPath ).toBe( customPath );
					expect( fileExists( customPath ) ).toBeTrue();
					// Neither the configured path nor the adjacent fallback won.
					expect( fileExists( configuredPath ) ).toBeFalse();
					expect( fileExists( variables.tempDir & "custom/sitemap.xml.meta.json" ) ).toBeFalse();
				} finally {
					settings.metadataPath = savedPath;
				}
			} );

			it( "uses the module metadataPath when the argument is omitted", function(){
				var settings       = getInstance( "coldbox:moduleSettings:sitemap-spider" );
				var savedPath      = settings.metadataPath;
				var configuredPath = variables.tempDir & "configured/default.meta.json";
				var sitemapPath    = variables.tempDir & "configured/sitemap.xml";
				settings.metadataPath = configuredPath;
				try {
					var result = variables.service.create(
						url           = variables.appRoot,
						filePath      = sitemapPath,
						writeMetadata = true
					);
					expect( result.metadataSaved ).toBeTrue();
					expect( result.metadataPath ).toBe( configuredPath );
					expect( fileExists( configuredPath ) ).toBeTrue();
					expect( fileExists( sitemapPath & ".meta.json" ) ).toBeFalse();

					// A sitemap path follows the module default; an explicit
					// sidecar path is always read literally.
					expect( variables.service.readMetadata( sitemapPath ).exists ).toBeTrue();
					expect( variables.service.readMetadata( configuredPath ).exists ).toBeTrue();
				} finally {
					settings.metadataPath = savedPath;
				}
			} );

			it( "lets an explicit empty metadataPath force adjacent derivation", function(){
				var settings       = getInstance( "coldbox:moduleSettings:sitemap-spider" );
				var savedPath      = settings.metadataPath;
				var configuredPath = variables.tempDir & "configured/should-not-exist.meta.json";
				var sitemapPath    = variables.tempDir & "adjacent/sitemap.xml";
				settings.metadataPath = configuredPath;
				try {
					var result = variables.service.create(
						url           = variables.appRoot,
						filePath      = sitemapPath,
						writeMetadata = true,
						metadataPath  = ""
					);
					expect( result.metadataSaved ).toBeTrue();
					expect( result.metadataPath ).toBe( sitemapPath & ".meta.json" );
					expect( fileExists( result.metadataPath ) ).toBeTrue();
					expect( fileExists( configuredPath ) ).toBeFalse();
				} finally {
					settings.metadataPath = savedPath;
				}
			} );

			it( "does not write configured metadata when writeMetadata is false", function(){
				var settings       = getInstance( "coldbox:moduleSettings:sitemap-spider" );
				var savedPath      = settings.metadataPath;
				var configuredPath = variables.tempDir & "disabled/should-not-exist.meta.json";
				settings.metadataPath = configuredPath;
				try {
					var result = variables.service.create(
						url      = variables.appRoot,
						filePath = variables.tempDir & "disabled/sitemap.xml"
					);
					expect( result.metadataSaved ).toBeFalse();
					expect( result.metadataPath ).toBe( "" );
					expect( fileExists( configuredPath ) ).toBeFalse();
				} finally {
					settings.metadataPath = savedPath;
				}
			} );

			it( "includes bad URL and ignored details when metadataIncludeUrls is true", function(){
				var result = variables.service.create(
					url                 = variables.appRoot,
					filePath            = variables.tempDir & "detailed/sitemap.xml",
					writeMetadata       = true,
					metadataIncludeUrls = true
				);
				var metadata = deserializeJSON( fileRead( result.metadataPath ) );
				// index.cfm links missing.cfm, which returns 500.
				expect( metadata ).toHaveKey( "badUrls" );
				expect( metadata.badUrls ).toHaveKey( variables.appRoot & "missing.cfm" );
				expect( metadata ).toHaveKey( "ignored" );
				expect( metadata.ignored ).toBeArray();
			} );

			it( "derives the sidecar name from the pre-gzip filename when gzipOutput is on", function(){
				var settings   = getInstance( "coldbox:moduleSettings:sitemap-spider" );
				var savedFlag  = settings.gzipOutput;
				settings.gzipOutput = true;
				try {
					var result = variables.service.create(
						url           = variables.appRoot,
						filePath      = variables.tempDir & "gz/sitemap.xml",
						writeMetadata = true
					);
					// The sitemap gained ".gz"; the sidecar name comes from the
					// pre-gzip filename and is never gzipped itself.
					expect( result.filePath ).toBe( variables.tempDir & "gz/sitemap.xml.gz" );
					expect( result.metadataPath ).toBe( variables.tempDir & "gz/sitemap.xml.meta.json" );
					expect( fileExists( result.metadataPath ) ).toBeTrue();
					var metadata = deserializeJSON( fileRead( result.metadataPath ) );
					// The sidecar records the file that exists on disk (.gz).
					expect( metadata.filePath ).toBe( variables.tempDir & "gz/sitemap.xml.gz" );
					expect( metadata.options.gzipOutput ).toBeTrue();
				} finally {
					settings.gzipOutput = savedFlag;
				}
			} );

		} );

		describe( "readMetadata()", function(){

			it( "round-trips given either the sidecar path or the sitemap path", function(){
				var fromSidecar = variables.service.readMetadata( variables.metaResult.metadataPath );
				var fromSitemap = variables.service.readMetadata( variables.metaFilePath );

				expect( fromSidecar.exists ).toBeTrue();
				expect( fromSitemap.exists ).toBeTrue();
				expect( fromSidecar.stats.urlCount ).toBe( variables.metaResult.stats.urlCount );
				expect( fromSitemap.stats.generatedAt ).toBe( variables.metaResult.stats.generatedAt );
			} );

			it( "accepts the gzipped sitemap path too", function(){
				// The gz spec above wrote this pair; ".gz" is stripped before the
				// sidecar name is derived.
				var metadata = variables.service.readMetadata( variables.tempDir & "gz/sitemap.xml.gz" );
				expect( metadata.exists ).toBeTrue();
			} );

			it( "returns exists=false when the file is missing", function(){
				var metadata = variables.service.readMetadata( variables.tempDir & "nothing-here/sitemap.xml" );
				expect( metadata ).toBe( { "exists": false } );
			} );

			it( "returns exists=false for unreadable JSON", function(){
				var garbagePath = variables.tempDir & "garbage/sitemap.xml.meta.json";
				if ( !directoryExists( getDirectoryFromPath( garbagePath ) ) ) {
					// The temp root already exists, so the single-argument form is
					// sufficient and stays compatible with Adobe ColdFusion.
					directoryCreate( getDirectoryFromPath( garbagePath ) );
				}
				fileWrite( garbagePath, "this is not json {" );
				var metadata = variables.service.readMetadata( garbagePath );
				expect( metadata ).toBe( { "exists": false } );
			} );

		} );
	}

}
