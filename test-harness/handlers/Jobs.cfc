/**
 * Demo dashboard for background sitemap jobs.
 *
 * Shows how a host app uses SitemapJobRegistry: queue a crawl, list running and
 * finished jobs with live progress, cancel one, and download the saved file. The
 * view polls the status action for live updates.
 */
component {

    property name="registry" inject="SitemapJobRegistry@sitemap-spider";

    /**
     * Renders the job list. The view also polls status() for live refreshes.
     */
    any function index( event, rc, prc ) {
        prc.jobs = registry.listJobs();
        event.setView( "jobs/index" );
    }

    /**
     * Queues a crawl for the submitted URL and returns to the list. Each job writes
     * to its own temp file, since a background job has no response to stream.
     */
    any function queue( event, rc, prc ) {
        param name="rc.url" default="";
        param name="rc.runAsync" default="false";

        if ( len( trim( rc.url ) ) ) {
            var dir      = getTempDirectory() & "sitemap-jobs/";
            var filePath = dir & createUUID() & ".xml";
            registry.queue(
                url      = trim( rc.url ),
                filePath = filePath,
                runAsync = isBoolean( rc.runAsync ) && rc.runAsync
            );
        }
        relocate( "jobs" );
    }

    /**
     * Returns the current job list as JSON, for the view's polling refresh.
     */
    any function status( event, rc, prc ) {
        event.renderData( type = "json", data = registry.listJobs() );
    }

    /**
     * Cancels a job and returns to the list.
     */
    any function cancel( event, rc, prc ) {
        param name="rc.id" default="";
        if ( len( rc.id ) ) {
            registry.cancel( rc.id );
        }
        relocate( "jobs" );
    }

    /**
     * Removes a job record and returns to the list.
     */
    any function remove( event, rc, prc ) {
        param name="rc.id" default="";
        if ( len( rc.id ) ) {
            registry.remove( rc.id );
        }
        relocate( "jobs" );
    }

    /**
     * Streams a finished job's saved sitemap file as a download. Prefers the actual
     * written path (which may carry ".gz") recorded in the job's progress summary,
     * falling back to the requested filePath.
     */
    any function download( event, rc, prc ) {
        param name="rc.id" default="";
        var job = registry.getJob( rc.id );

        // Prefer the path actually written, which the job records in result and
        // which may carry ".gz"; fall back to the path the job was queued with.
        var path = "";
        if ( job.keyExists( "result" ) && isStruct( job.result ) && job.result.keyExists( "filePath" ) && len( job.result.filePath ) ) {
            path = job.result.filePath;
        } else if ( job.keyExists( "filePath" ) ) {
            path = job.filePath;
        }

        if ( !len( path ) || !fileExists( path ) ) {
            event.setHTTPHeader( statusCode = 404, statusText = "Not Found" );
            event.renderData( type = "plain", data = "No downloadable file for this job." );
            return;
        }

        event.noRender();
        cfheader( name = "Content-Disposition", value = 'attachment; filename="#getFileFromPath( path )#"' );
        cfcontent( type = "application/xml; charset=utf-8", file = path, deleteFile = false );
    }

}
