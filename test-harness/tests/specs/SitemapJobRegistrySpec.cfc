/**
 * Integration specs for SitemapJobRegistry.cfc.
 *
 * The registry runs real crawls of the sample site (the same site ModuleSpec
 * crawls) on its background thread pool, so these specs queue jobs and poll until
 * they finish. They prove: a queued job completes and writes its file, several
 * jobs run and finish independently, the job pool drains a backlog, cancel/remove
 * work, and queue() requires a filePath.
 *
 * The registry is a singleton, so getInstance returns the one shared instance with
 * its one job pool. Each job writes to its own temp file, cleaned up in afterAll.
 *
 * Local run recipe:
 *   1. box server start serverConfigFile=server-adobe@2023.json
 *   2. box testbox run runner="http://localhost:61002/tests/runner.cfm" bundles="tests.specs.SitemapJobRegistrySpec"
 */
component extends="coldbox.system.testing.BaseTestCase" appMapping="root" {

    variables.serverRoot = "http#( CGI.HTTPS == "on" ? 's' : '' )#://" & CGI.HTTP_HOST & "/";

    function beforeAll(){
        super.beforeAll();
        setup();

        variables.appRoot  = variables.serverRoot & "tests/resources/sample-site/";
        variables.registry = getInstance( "SitemapJobRegistry@sitemap-spider" );
        variables.tempDir  = getTempDirectory() & "sitemap-job-tests/";
        // Files and job ids created by the specs, cleaned up below.
        variables.createdFiles = [];
        variables.createdJobs  = [];
    }

    function afterAll(){
        // Remove the job records and any files written.
        for ( var jobId in variables.createdJobs ) {
            variables.registry.remove( jobId );
        }
        for ( var f in variables.createdFiles ) {
            if ( len( f ) && fileExists( f ) ) {
                fileDelete( f );
            }
        }
        super.afterAll();
    }

    // A unique temp file path for a job, tracked for cleanup.
    private string function tempFile(){
        var path = variables.tempDir & createUUID() & ".xml";
        variables.createdFiles.append( path );
        return path;
    }

    // Queues a sample-site crawl and tracks the job id for cleanup.
    private string function queueSampleCrawl(){
        var jobId = variables.registry.queue( url = variables.appRoot, filePath = tempFile() );
        variables.createdJobs.append( jobId );
        return jobId;
    }

    // Polls a job until it reaches a terminal status or the timeout passes, then
    // returns the final job struct. A generous timeout keeps a slow engine from
    // failing a correct crawl.
    private struct function waitForTerminal( required string jobId, numeric timeoutMs = 30000 ){
        var terminal = [ "completed", "failed", "canceled" ];
        var deadline = getTickCount() + arguments.timeoutMs;
        while ( getTickCount() < deadline ) {
            var job = variables.registry.getJob( arguments.jobId );
            if ( structIsEmpty( job ) ) {
                return {};
            }
            if ( arrayContains( terminal, job.status ) ) {
                return job;
            }
            sleep( 100 );
        }
        return variables.registry.getJob( arguments.jobId );
    }

    function run(){
        describe( "SitemapJobRegistry", function(){

            it( "queues a crawl, completes it, and writes the file", function(){
                var jobId = queueSampleCrawl();

                var job = waitForTerminal( jobId );
                expect( job.status ).toBe( "completed" );
                expect( job.progress.pagesFound ).toBeGT( 0 );
                expect( job.result.saved ).toBeTrue();
                expect( fileExists( job.result.filePath ) ).toBeTrue();
            } );

            it( "getJob returns the record shape with progress and result structs", function(){
                var jobId = queueSampleCrawl();
                var job   = waitForTerminal( jobId );

                expect( job ).toHaveKey( "id" );
                expect( job ).toHaveKey( "status" );
                expect( job ).toHaveKey( "url" );
                expect( job ).toHaveKey( "filePath" );
                expect( job ).toHaveKey( "progress" );
                expect( job ).toHaveKey( "result" );
                expect( job ).toHaveKey( "meta" );
                expect( job ).toHaveKey( "attempts" );
                expect( job ).toHaveKey( "ownerId" );
                expect( job.id ).toBe( jobId );
                expect( job.url ).toBe( variables.appRoot );
                // Claiming the job to run it counts as one attempt.
                expect( job.attempts ).toBe( 1 );
            } );

            it( "stores the host's meta struct and filters listJobs by it", function(){
                var siteId = "site-" & createUUID();
                var jobId  = variables.registry.queue(
                    url      = variables.appRoot,
                    filePath = tempFile(),
                    meta     = { "siteId" : siteId, "customerId" : "acme" }
                );
                variables.createdJobs.append( jobId );
                waitForTerminal( jobId );

                expect( variables.registry.getJob( jobId ).meta.siteId ).toBe( siteId );

                var mine = variables.registry.listJobs( { "siteId" : siteId } );
                expect( mine.len() ).toBe( 1 );
                expect( mine[ 1 ].id ).toBe( jobId );

                // A meta value nothing was queued with matches nothing.
                expect( variables.registry.listJobs( { "siteId" : "nope" } ).len() ).toBe( 0 );
            } );

            it( "runs two crawls and completes both independently", function(){
                var jobA = queueSampleCrawl();
                var jobB = queueSampleCrawl();

                var a = waitForTerminal( jobA );
                var b = waitForTerminal( jobB );

                expect( a.status ).toBe( "completed" );
                expect( b.status ).toBe( "completed" );
                expect( a.id ).notToBe( b.id );
                expect( a.progress.pagesFound ).toBeGT( 0 );
                expect( b.progress.pagesFound ).toBeGT( 0 );
            } );

            it( "drains a backlog larger than the pool: every queued job finishes", function(){
                // Queue more jobs than maxConcurrentJobs so some start as queued and
                // are promoted as slots free. All must reach completed.
                var jobIds = [];
                for ( var i = 1; i <= 5; i++ ) {
                    jobIds.append( queueSampleCrawl() );
                }

                for ( var jobId in jobIds ) {
                    expect( waitForTerminal( jobId ).status ).toBe( "completed" );
                }
            } );

            it( "lists queued and finished jobs", function(){
                var jobId = queueSampleCrawl();
                waitForTerminal( jobId );

                var found = false;
                for ( var job in variables.registry.listJobs() ) {
                    if ( job.id == jobId ) {
                        found = true;
                    }
                }
                expect( found ).toBeTrue();
            } );

            it( "cancel() returns false for an unknown job", function(){
                expect( variables.registry.cancel( "no-such-job" ) ).toBeFalse();
            } );

            it( "runs a job with the backend named on the job", function(){
                // Naming the default backend explicitly is the same thing a host
                // does for a site that needs Playwright, without needing the
                // Playwright driver installed to test the plumbing.
                var jobId = variables.registry.queue(
                    url        = variables.appRoot,
                    filePath   = tempFile(),
                    browserDsl = "Jsoup@sitemap-spider"
                );
                variables.createdJobs.append( jobId );

                var job = waitForTerminal( jobId );
                expect( job.status ).toBe( "completed" );
                expect( job.browserDsl ).toBe( "Jsoup@sitemap-spider" );
                expect( job.progress.pagesFound ).toBeGT( 0 );
            } );

            it( "runs a job with the extension flags named on the job", function(){
                // The module settings leave all three off. Turning videos on for
                // this one job is what a portal does for a site whose sitemap
                // should carry them, without touching global config. index.cfm
                // carries a <video> tag, so the finished file has a video block.
                var jobId = variables.registry.queue(
                    url           = variables.appRoot,
                    filePath      = tempFile(),
                    includeVideos = true
                );
                variables.createdJobs.append( jobId );

                var job = waitForTerminal( jobId );
                expect( job.status ).toBe( "completed" );
                expect( job.includeVideos ).toBeTrue();
                expect( job.includeImages ).toBeFalse();

                var xml = fileRead( job.result.filePath );
                expect( xml ).toInclude( "<video:video>" );
                expect( xml ).notToInclude( "<image:image>" );
            } );

            it( "stores the stats struct on a completed job record", function(){
                var jobId = queueSampleCrawl();

                var job = waitForTerminal( jobId );
                expect( job.status ).toBe( "completed" );
                expect( job.result ).toHaveKey( "stats" );
                expect( job.result.stats.urlCount ).toBeGT( 0 );
                expect( job.result.stats ).toHaveKey( "generatedAt,durationMs,badUrlCount" );
                // Metadata was not asked for, so nothing extra was written.
                expect( job.result.metadataSaved ).toBeFalse();
            } );

            it( "passes writeMetadata through so a queued job writes the sidecar", function(){
                var sitemapPath = tempFile();
                // Track the sidecar for cleanup too.
                variables.createdFiles.append( sitemapPath & ".meta.json" );

                var jobId = variables.registry.queue(
                    url           = variables.appRoot,
                    filePath      = sitemapPath,
                    writeMetadata = true
                );
                variables.createdJobs.append( jobId );

                var job = waitForTerminal( jobId );
                expect( job.status ).toBe( "completed" );
                expect( job.result.metadataSaved ).toBeTrue();
                expect( job.result.metadataPath ).toBe( sitemapPath & ".meta.json" );
                expect( fileExists( job.result.metadataPath ) ).toBeTrue();
            } );

            it( "snapshots the module metadataPath when the job is queued", function(){
                var settings       = getInstance( "coldbox:moduleSettings:sitemap-spider" );
                var savedPath      = settings.metadataPath;
                var configuredPath = variables.tempDir & createUUID() & ".meta.json";
                var laterPath      = variables.tempDir & createUUID() & ".meta.json";
                variables.createdFiles.append( configuredPath );
                variables.createdFiles.append( laterPath );

                settings.metadataPath = configuredPath;
                try {
                    var jobId = variables.registry.queue(
                        url           = variables.appRoot,
                        filePath      = tempFile(),
                        writeMetadata = true
                    );
                    variables.createdJobs.append( jobId );

                    // Changing the setting after queue() must not move this job.
                    settings.metadataPath = laterPath;
                    var queued = variables.registry.getJob( jobId );
                    expect( queued.metadataPath ).toBe( configuredPath );

                    var job = waitForTerminal( jobId );
                    expect( job.status ).toBe( "completed" );
                    expect( job.result.metadataPath ).toBe( configuredPath );
                    expect( fileExists( configuredPath ) ).toBeTrue();
                    expect( fileExists( laterPath ) ).toBeFalse();
                } finally {
                    settings.metadataPath = savedPath;
                }
            } );

            it( "falls back to the module setting for a record queued before the flags existed", function(){
                // A record a persistent store was already holding when the host
                // upgraded has no include* keys, so runJob reads them through
                // recordFlag rather than straight off the record.
                var registry = prepareMock( getInstance( "SitemapJobRegistry@sitemap-spider" ) );
                makePublic( registry, "recordFlag" );
                makePublic( registry, "recordMetadataPath" );
                var settings = getInstance( "coldbox:moduleSettings:sitemap-spider" );
                var savedPath = settings.metadataPath;
                settings.metadataPath = "/private/configured.meta.json";

                try {
                    expect( registry.recordFlag( {}, "includeVideos" ) ).toBe( settings.includeVideos );
                    expect( registry.recordFlag( { "includeVideos" : true }, "includeVideos" ) ).toBeTrue();
                    expect( registry.recordFlag( { "includeVideos" : false }, "includeVideos" ) ).toBeFalse();
                    expect( registry.recordMetadataPath( {} ) ).toBe( settings.metadataPath );
                    expect( registry.recordMetadataPath( { "metadataPath" : "" } ) ).toBe( "" );
                    expect( registry.recordMetadataPath( { "metadataPath" : "/job.meta.json" } ) )
                        .toBe( "/job.meta.json" );
                } finally {
                    settings.metadataPath = savedPath;
                }
            } );

            it( "tells the host app when a job finishes", function(){
                // The events are how a host uploads the finished file or emails
                // someone, without this module knowing about any of that. Listen the
                // way a host would and check the job's events arrive.
                var seen = [];
                var interceptors = getInstance( "coldbox:interceptorService" );
                interceptors.listen(
                    target = function( event, data, buffer, rc, prc ){
                        seen.append( arguments.data.record.status );
                    },
                    point = "onSitemapJobCompleted"
                );

                var jobId = queueSampleCrawl();
                waitForTerminal( jobId );
                // The listener runs on the job's own thread, so give it a moment.
                sleep( 250 );

                expect( seen ).toInclude( "completed" );
            } );

            it( "cancel() on a running/queued job drives it to a terminal state", function(){
                var jobId = queueSampleCrawl();
                // Ask to cancel right away. Depending on timing the crawl may finish
                // first (completed) or stop early (canceled); either is a valid
                // terminal outcome. The point is cancel never wedges the job.
                variables.registry.cancel( jobId );

                var job = waitForTerminal( jobId );
                expect( [ "completed", "canceled" ] ).toInclude( job.status );
            } );

            it( "remove() drops a finished job from the registry", function(){
                var jobId = queueSampleCrawl();
                waitForTerminal( jobId );

                variables.registry.remove( jobId );
                expect( variables.registry.getJob( jobId ) ).toBeEmpty();
            } );

            it( "queue() requires a filePath", function(){
                expect( function(){
                    variables.registry.queue( url = variables.appRoot, filePath = "" );
                } ).toThrow( type = "sitemap-spider.FilePathRequired" );
            } );

        } );
    }

}
