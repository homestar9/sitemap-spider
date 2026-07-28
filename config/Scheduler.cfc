/**
 * Background upkeep for sitemap jobs.
 *
 * ColdBox finds this file automatically because of where it sits (config/
 * alongside ModuleConfig.cfc), builds it, starts it when the app boots, and stops
 * it on a reinit or shutdown. A host app does not have to wire anything up. It
 * also does not need this file at all unless it queues background jobs through
 * SitemapJobRegistry — the tasks below do nothing when there are none.
 *
 * There is no `extends` here on purpose: ColdBox gives this component the
 * scheduler methods (task, getInstance, setTimezone) when it loads it, and injects
 * moduleSettings so the tasks can read this module's own settings.
 *
 * Three tasks, all driven by settings in ModuleConfig.cfc:
 *
 * 1. recover-interrupted-jobs, once shortly after startup. Jobs left on "running"
 *    by a previous start of this app server are dead — their threads went away
 *    with it — so they are marked interrupted and a host can retry them.
 *
 * 2. record-job-progress, on a timer. Writes each running job's counters to the
 *    job store. That is what lets a dashboard show progress for a job running on
 *    another server, and it is the "still alive" signal task 3 reads.
 *
 * 3. recover-dead-jobs, on a timer. Marks jobs whose progress stopped being
 *    reported. This is the only thing that catches a killed server, an
 *    out-of-memory, or a stopped container, because no shutdown code runs then.
 */
component {

	/**
	 * Registers the upkeep tasks. Called once when ColdBox loads this scheduler.
	 */
	function configure(){
		// Runs once, a little after boot rather than during it, so a slow job
		// store never holds up the first request. No repeat interval, so it fires
		// a single time.
		task( "sitemap-spider:recover-interrupted-jobs" )
			.call( function(){
				var recovered = getInstance( "SitemapJobRegistry@sitemap-spider" ).sweepOrphanedJobs();
				if ( recovered > 0 ) {
					out( "sitemap-spider: marked #recovered# job(s) interrupted after a restart" );
				}
			} )
			.delay( 10, "seconds" )
			.onFailure( function( task, exception ){
				err( "sitemap-spider: could not recover jobs after restart: #exception.message#" );
			} );

		task( "sitemap-spider:record-job-progress" )
			.call( function(){
				getInstance( "SitemapJobRegistry@sitemap-spider" ).heartbeatRunningJobs();
			} )
			.every( max( 1, variables.moduleSettings.jobHeartbeatSeconds ), "seconds" )
			// Waits for one run to finish before starting the next, so a slow store
			// cannot stack these up.
			.withNoOverlaps()
			.onFailure( function( task, exception ){
				err( "sitemap-spider: could not record job progress: #exception.message#" );
			} );

		task( "sitemap-spider:recover-dead-jobs" )
			.call( function(){
				var recovered = getInstance( "SitemapJobRegistry@sitemap-spider" ).reapStaleJobs();
				if ( recovered > 0 ) {
					out( "sitemap-spider: marked #recovered# job(s) interrupted after their process died" );
				}
			} )
			.every( max( 5, variables.moduleSettings.jobReaperIntervalSeconds ), "seconds" )
			.withNoOverlaps()
			// Lets a host switch this off through module settings alone, for
			// example when something outside the app handles cleanup.
			.when( function(){
				return variables.moduleSettings.jobReaperEnabled;
			} )
			.onFailure( function( task, exception ){
				err( "sitemap-spider: could not recover dead jobs: #exception.message#" );
			} );
	}

}
