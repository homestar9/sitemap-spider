/**
 * Tests writing and reading link reports while crawling the sample site.
 */
component extends="coldbox.system.testing.BaseTestCase" appMapping="root" {

	variables.serverRoot = "http#( CGI.HTTPS == "on" ? 's' : '' )#://" & CGI.HTTP_HOST & "/";

	/**
	 * beforeAll
	 *
	 * Crawls the sample site once with and once without the report.
	 */
	function beforeAll(){
		super.beforeAll();
		setup();

		variables.appRoot = variables.serverRoot & "tests/resources/sample-site/";
		variables.tempDir = getTempDirectory() & "sitemap-spider-linkreport-spec/";
		variables.service = getInstance( "sitemapService@sitemap-spider" );

		// Save a sitemap with the report disabled.
		variables.plainFilePath = variables.tempDir & "plain/sitemap.xml";
		variables.plainResult   = variables.service.create(
			url      = variables.appRoot,
			filePath = variables.plainFilePath
		);

		// Save the report beside the sitemap.
		variables.reportFilePath = variables.tempDir & "report/sitemap.xml";
		variables.reportResult   = variables.service.create(
			url             = variables.appRoot,
			filePath        = variables.reportFilePath,
			writeLinkReport = true
		);
	}

	/**
	 * afterAll
	 *
	 * Removes the files these specs wrote.
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
	 * Defines the LinkReportSpec examples.
	 */
	function run(){

		describe( "link report sidecar", function(){

			it( "writes no report by default", function(){
				expect( variables.plainResult.saved ).toBeTrue();
				expect( variables.plainResult.linkReportSaved ).toBeFalse();
				expect( variables.plainResult.linkReportPath ).toBe( "" );
				expect( fileExists( variables.plainFilePath & ".links.json" ) ).toBeFalse();
			} );

			it( "writes the report beside the sitemap when writeLinkReport is true", function(){
				expect( variables.reportResult.linkReportSaved ).toBeTrue();
				expect( variables.reportResult.linkReportPath ).toBe( variables.reportFilePath & ".links.json" );
				expect( fileExists( variables.reportResult.linkReportPath ) ).toBeTrue();
			} );

			it( "records the schema version, site, and timestamp", function(){
				var report = deserializeJSON( fileRead( variables.reportResult.linkReportPath ) );

				expect( report.schemaVersion ).toBe( 1 );
				expect( report.site ).toBe( variables.appRoot );
				// The report and the stats describe the same run.
				expect( report.generatedAt ).toBe( variables.reportResult.stats.generatedAt );
				expect( len( report.moduleVersion ) ).toBeGT( 0 );
			} );

			it( "lists the broken links found on the sample site", function(){
				var report = deserializeJSON( fileRead( variables.reportResult.linkReportPath ) );

				var brokenUrls = [];
				for ( var entry in report.broken ) {
					brokenUrls.append( entry.url );
				}
				expect( brokenUrls ).toInclude( variables.appRoot & "missing.cfm" );
				expect( report.summary.broken ).toBe( report.broken.len() );
			} );

			it( "names the page each broken link was found on", function(){
				var report = deserializeJSON( fileRead( variables.reportResult.linkReportPath ) );

				for ( var entry in report.broken ) {
					if ( entry.url == variables.appRoot & "missing.cfm" ) {
						expect( entry.foundOn ).toBe( [ variables.appRoot ] );
					}
				}
			} );

			it( "lists the URLs the crawler deliberately skipped", function(){
				var report = deserializeJSON( fileRead( variables.reportResult.linkReportPath ) );

				var reasons = {};
				for ( var entry in report.skipped ) {
					reasons[ entry.url ] = entry.reason;
				}
				expect( reasons ).toHaveKey( variables.appRoot & "nofollow.cfm" );
				expect( reasons[ variables.appRoot & "nofollow.cfm" ] ).toBe( "nofollow" );
				expect( reasons ).toHaveKey( variables.appRoot & "disallow.cfm" );
				expect( reasons[ variables.appRoot & "disallow.cfm" ] ).toBe( "disallowed" );
			} );

			it( "does not change the sitemap XML it was generated alongside", function(){
				// Creating the report must not change the sitemap.
				expect( variables.reportResult.sitemap ).toBe( variables.plainResult.sitemap );
			} );

		} );

		describe( "link report path handling", function(){

			it( "writes the report to a caller-specified linkReportPath", function(){
				var customPath = variables.tempDir & "private/links.json";
				var result     = variables.service.create(
					url             = variables.appRoot,
					filePath        = variables.tempDir & "custom/sitemap.xml",
					writeLinkReport = true,
					linkReportPath  = customPath
				);

				expect( result.linkReportPath ).toBe( customPath );
				expect( fileExists( customPath ) ).toBeTrue();
			} );

			it( "strips .gz so a compressed sitemap gets a plain sidecar name", function(){
				var settings = getInstance( "coldbox:moduleSettings:sitemap-spider" );
				var saved    = settings.gzipOutput;
				settings.gzipOutput = true;
				try {
					var filePath = variables.tempDir & "gzip/sitemap.xml";
					var result   = variables.service.create(
						url             = variables.appRoot,
						filePath        = filePath,
						writeLinkReport = true
					);

					expect( result.filePath ).toBe( filePath & ".gz" );
					expect( result.linkReportPath ).toBe( filePath & ".links.json" );
					// The report stays plain JSON when the sitemap uses gzip.
					expect( isJSON( fileRead( result.linkReportPath ) ) ).toBeTrue();
				} finally {
					settings.gzipOutput = saved;
				}
			} );

			it( "writes no report when there is no path to write it to", function(){
				var result = variables.service.create(
					url             = variables.appRoot,
					writeLinkReport = true
				);

				expect( result.linkReportSaved ).toBeFalse();
				expect( result.linkReportPath ).toBe( "" );
			} );

			it( "throws LinkReportSaveFailed when the report cannot be written", function(){
				expect( function(){
					variables.service.create(
						url             = variables.appRoot,
						filePath        = variables.tempDir & "bad/sitemap.xml",
						writeLinkReport = true,
						// A directory cannot be overwritten with a file.
						linkReportPath  = variables.tempDir
					);
				} ).toThrow( type = "sitemap-spider.LinkReportSaveFailed" );
			} );

		} );

		describe( "readLinkReport()", function(){

			it( "reads a report back from its own path", function(){
				var report = variables.service.readLinkReport( variables.reportResult.linkReportPath );

				expect( report.exists ).toBeTrue();
				expect( report.schemaVersion ).toBe( 1 );
			} );

			it( "derives the report path from a sitemap path", function(){
				var report = variables.service.readLinkReport( variables.reportFilePath );

				expect( report.exists ).toBeTrue();
				expect( report.site ).toBe( variables.appRoot );
			} );

			it( "returns exists=false when no report was written", function(){
				expect( variables.service.readLinkReport( variables.plainFilePath ).exists ).toBeFalse();
			} );

			it( "returns exists=false when the file is not valid JSON", function(){
				var brokenPath = variables.tempDir & "broken/report.links.json";
				// Adobe CFML does not support directoryCreate()'s ignoreExists argument.
				var brokenDir = getDirectoryFromPath( brokenPath );
				if ( !directoryExists( brokenDir ) ) {
					directoryCreate( brokenDir );
				}
				fileWrite( brokenPath, "this is not json" );

				expect( variables.service.readLinkReport( brokenPath ).exists ).toBeFalse();
			} );

		} );

		describe( "link report counts in stats", function(){

			it( "adds broken and asset counts beside the existing counts", function(){
				var stats = variables.reportResult.stats;

				expect( stats ).toHaveKey( "badUrlCount,ignoredCount,redirectCount,assetsCheckedCount,assetsBrokenCount" );
				// Asset checking is disabled by default.
				expect( stats.assetsCheckedCount ).toBe( 0 );
				expect( stats.assetsBrokenCount ).toBe( 0 );
			} );

			it( "matches the report summary to the crawl counts", function(){
				var report = deserializeJSON( fileRead( variables.reportResult.linkReportPath ) );

				expect( report.summary.broken ).toBe( variables.reportResult.stats.badUrlCount );
				expect( report.summary.skipped ).toBe( variables.reportResult.stats.ignoredCount );
				expect( report.summary.redirected ).toBe( variables.reportResult.stats.redirectCount );
			} );

		} );

	}

}
