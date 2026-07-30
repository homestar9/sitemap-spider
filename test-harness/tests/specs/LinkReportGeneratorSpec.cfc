/**
 * Tests link report fields, counts, and sorting without making HTTP requests.
 */
component extends="coldbox.system.testing.BaseTestCase" appMapping="root" {

	/**
	 * beforeAll
	 *
	 * Loads the generator under test.
	 */
	function beforeAll(){
		super.beforeAll();
		setup();

		variables.generator = getInstance( "LinkReportGenerator@sitemap-spider" );
		variables.root      = "http://example.test/";
	}

	/**
	 * afterAll
	 *
	 * Restores shared state changed by these specs.
	 */
	function afterAll(){
		super.afterAll();
	}

	/**
	 * badUrl
	 *
	 * Returns one badUrls entry in the shape Crawler produces.
	 *
	 * @status HTTP status, or 0 when there was no response.
	 * @reason Failure category.
	 * @kind "page" or "asset".
	 * @foundOn Pages that link to the failed URL.
	 */
	private struct function badUrl(
		numeric status  = 404,
		string reason   = "notFound",
		string kind     = "page",
		array foundOn   = []
	){
		return {
			"message"          : "failed",
			"status"           : arguments.status,
			"reason"           : arguments.reason,
			"kind"             : arguments.kind,
			"redirectChain"    : [],
			"foundOn"          : arguments.foundOn,
			"foundOnTruncated" : false
		};
	}

	/**
	 * crawlResult
	 *
	 * Returns a crawl result with the keys the generator reads.
	 *
	 * @badUrls URL to failure entry.
	 * @redirects Redirect entries.
	 * @ignored Skipped URL entries.
	 * @processedUrls URLs the crawler claimed for a fetch.
	 * @assetsChecked How many assets were checked.
	 */
	private struct function crawlResult(
		struct badUrls      = {},
		array redirects     = [],
		array ignored       = [],
		array processedUrls = [],
		numeric assetsChecked = 0
	){
		return {
			"badUrls"       : arguments.badUrls,
			"redirects"     : arguments.redirects,
			"ignored"       : arguments.ignored,
			"processedUrls" : arguments.processedUrls,
			"assetsChecked" : arguments.assetsChecked
		};
	}

	/**
	 * run
	 *
	 * Defines the LinkReportGeneratorSpec examples.
	 */
	function run(){

		describe( "generate() report shape", function(){

			it( "returns empty lists for a crawl with nothing to report", function(){
				var report = variables.generator.generate( crawlResult() );

				expect( report.broken ).toBeEmpty();
				expect( report.redirects ).toBeEmpty();
				expect( report.skipped ).toBeEmpty();
				expect( report.summary.broken ).toBe( 0 );
			} );

			it( "stamps the site, version, and timestamp it was given", function(){
				var report = variables.generator.generate(
					crawlResult   = crawlResult(),
					site          = variables.root,
					moduleVersion = "1.2.3",
					generatedAt   = "2026-07-30T09:00:00-05:00"
				);

				expect( report.schemaVersion ).toBe( 1 );
				expect( report.site ).toBe( variables.root );
				expect( report.moduleVersion ).toBe( "1.2.3" );
				expect( report.generatedAt ).toBe( "2026-07-30T09:00:00-05:00" );
			} );

			it( "copies the status, reason, and referrers for a broken URL", function(){
				var goneUrl = variables.root & "gone.cfm";
				var report  = variables.generator.generate(
					crawlResult( badUrls = {
						"#goneUrl#" : badUrl( foundOn = [ variables.root ] )
					} )
				);

				expect( report.broken.len() ).toBe( 1 );
				expect( report.broken[ 1 ].url ).toBe( goneUrl );
				expect( report.broken[ 1 ].status ).toBe( 404 );
				expect( report.broken[ 1 ].reason ).toBe( "notFound" );
				expect( report.broken[ 1 ].foundOn ).toBe( [ variables.root ] );
			} );

		} );

		describe( "generate() summary counts", function(){

			it( "counts pages and assets separately", function(){
				var report = variables.generator.generate(
					crawlResult(
						badUrls = {
							"#variables.root#gone.cfm"  : badUrl(),
							"#variables.root#logo.png"  : badUrl( kind = "asset" )
						},
						processedUrls = [ variables.root, variables.root & "gone.cfm" ],
						assetsChecked = 3
					)
				);

				expect( report.summary.pagesChecked ).toBe( 2 );
				expect( report.summary.assetsChecked ).toBe( 3 );
				// checked includes pages and assets.
				expect( report.summary.checked ).toBe( 5 );
				expect( report.summary.broken ).toBe( 2 );
				expect( report.summary.brokenAssets ).toBe( 1 );
			} );

			it( "counts redirects and skipped URLs", function(){
				var report = variables.generator.generate(
					crawlResult(
						redirects = [
							{ "from": variables.root & "old.cfm", "to": variables.root & "new.cfm", "status": 301 }
						],
						ignored = [
							{ "url": variables.root & "private.cfm", "reason": "disallowed" },
							{ "url": variables.root & "draft.cfm", "reason": "noindex" }
						]
					)
				);

				expect( report.summary.redirected ).toBe( 1 );
				expect( report.summary.skipped ).toBe( 2 );
			} );

		} );

		describe( "generate() redirects", function(){

			it( "marks a 301 permanent and a 302 temporary", function(){
				var report = variables.generator.generate(
					crawlResult( redirects = [
						{ "from": variables.root & "moved.cfm", "to": variables.root & "a.cfm", "status": 301 },
						{ "from": variables.root & "temp.cfm", "to": variables.root & "b.cfm", "status": 302 }
					] )
				);

				// Permanent redirects sort first.
				expect( report.redirects[ 1 ].status ).toBe( 301 );
				expect( report.redirects[ 1 ].permanent ).toBeTrue();
				expect( report.redirects[ 2 ].permanent ).toBeFalse();
			} );

			it( "treats a 308 as permanent too", function(){
				var report = variables.generator.generate(
					crawlResult( redirects = [
						{ "from": variables.root & "moved.cfm", "to": variables.root & "a.cfm", "status": 308 }
					] )
				);

				expect( report.redirects[ 1 ].permanent ).toBeTrue();
			} );

		} );

		describe( "generate() sort order", function(){

			it( "puts server errors before missing pages", function(){
				var report = variables.generator.generate(
					crawlResult( badUrls = {
						"#variables.root#gone.cfm"    : badUrl( status = 404, reason = "notFound" ),
						"#variables.root#timeout.cfm" : badUrl( status = 0, reason = "timeout" ),
						"#variables.root#boom.cfm"    : badUrl( status = 500, reason = "serverError" )
					} )
				);

				expect( report.broken[ 1 ].reason ).toBe( "serverError" );
				expect( report.broken[ 2 ].reason ).toBe( "notFound" );
				expect( report.broken[ 3 ].reason ).toBe( "timeout" );
			} );

			it( "sorts by URL within the same reason so runs are comparable", function(){
				var report = variables.generator.generate(
					crawlResult( badUrls = {
						"#variables.root#b.cfm" : badUrl(),
						"#variables.root#a.cfm" : badUrl()
					} )
				);

				expect( report.broken[ 1 ].url ).toBe( variables.root & "a.cfm" );
				expect( report.broken[ 2 ].url ).toBe( variables.root & "b.cfm" );
			} );

			it( "groups skipped URLs by reason", function(){
				var report = variables.generator.generate(
					crawlResult( ignored = [
						{ "url": variables.root & "z.cfm", "reason": "noindex" },
						{ "url": variables.root & "a.cfm", "reason": "disallowed" },
						{ "url": variables.root & "b.cfm", "reason": "noindex" }
					] )
				);

				expect( report.skipped[ 1 ].reason ).toBe( "disallowed" );
				expect( report.skipped[ 2 ].url ).toBe( variables.root & "b.cfm" );
				expect( report.skipped[ 3 ].url ).toBe( variables.root & "z.cfm" );
			} );

		} );

		describe( "generate() with older crawl results", function(){

			it( "fills in defaults when a badUrls entry has only a message", function(){
				var goneUrl = variables.root & "gone.cfm";
				var report  = variables.generator.generate(
					crawlResult( badUrls = { "#goneUrl#" : { "message": "boom" } } )
				);

				expect( report.broken[ 1 ].status ).toBe( 0 );
				expect( report.broken[ 1 ].reason ).toBe( "unknown" );
				expect( report.broken[ 1 ].kind ).toBe( "page" );
				expect( report.broken[ 1 ].foundOn ).toBeEmpty();
			} );

			it( "does not fail when the crawl result has no assetsChecked key", function(){
				var report = variables.generator.generate( {
					"badUrls"       : {},
					"redirects"     : [],
					"ignored"       : [],
					"processedUrls" : [ variables.root ]
				} );

				expect( report.summary.assetsChecked ).toBe( 0 );
				expect( report.summary.checked ).toBe( 1 );
			} );

		} );

	}

}
