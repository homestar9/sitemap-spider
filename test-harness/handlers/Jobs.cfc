/**
 * Shows background job progress and lets users queue, cancel, and download jobs.
 */
component {

    property name="registry" inject="SitemapJobRegistry@sitemap-spider";

    /**
     * index
     *
     * Renders the job list, which polls status() for updates.
     */
    any function index( event, rc, prc ) {
        prc.jobs = registry.listJobs();
        event.setView( "jobs/index" );
    }

    /**
     * queue
     *
     * Queues the submitted URL to a unique temporary file.
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
     * status
     *
     * Returns the current job list as JSON, for the view's polling refresh.
     */
    any function status( event, rc, prc ) {
        event.renderData( type = "json", data = registry.listJobs() );
    }

    /**
     * cancel
     *
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
     * remove
     *
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
     * download
     *
     * Downloads the saved sitemap for a finished job.
     */
    any function download( event, rc, prc ) {
        param name="rc.id" default="";
        var job = registry.getJob( rc.id );

        // Use result.filePath because gzip output adds .gz.
        // Older records can contain only the requested filePath.
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
