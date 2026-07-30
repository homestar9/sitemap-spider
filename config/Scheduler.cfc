/**
 * Maintains background sitemap jobs.
 *
 * ColdBox loads this scheduler automatically. It marks jobs from an earlier boot
 * interrupted, saves live progress, and marks stale jobs interrupted. Progress
 * and stale-job timers run only when IJobStore.isShared() is true.
 *
 * ColdBox supplies the scheduler methods, moduleSettings, and variables.log.
 * out() and err() belong to ScheduledTask and must not be called here.
 */
component {

	/**
	 * configure
	 *
	 * Registers startup recovery, heartbeat, and stale-job tasks.
	 */
	function configure(){
		// Decide at startup whether the repeating tasks need an executor.
		var scheduleTimerTasks = shouldScheduleTimerTasks();

		// Recover jobs after startup so a slow store does not delay the first request.
		task( "sitemap-spider:recover-interrupted-jobs" )
			.call( function(){
				var recovered = getInstance( "SitemapJobRegistry@sitemap-spider" ).sweepOrphanedJobs();
				if ( recovered > 0 ) {
					variables.log.info( "sitemap-spider: marked #recovered# job(s) interrupted after a restart" );
				}
			} )
			.delay( 10, "seconds" )
			.onFailure( function( task, exception ){
				variables.log.error( "sitemap-spider: could not recover jobs after restart: #exception.message#", exception );
			} );

		var progressTask = task( "sitemap-spider:record-job-progress" )
			.call( function(){
				getInstance( "SitemapJobRegistry@sitemap-spider" ).heartbeatRunningJobs();
			} )
			.every( max( 1, variables.moduleSettings.jobHeartbeatSeconds ), "seconds" )
			// Wait until application startup has finished.
			.delay( 30, "seconds" )
			// Do not overlap writes when the store is slow.
			.withNoOverlaps()
			.when( function(){
				return jobStoreIsShared();
			} )
			.onFailure( function( task, exception ){
				variables.log.error( "sitemap-spider: could not record job progress: #exception.message#", exception );
			} );

		var reaperTask = task( "sitemap-spider:recover-dead-jobs" )
			.call( function(){
				var recovered = getInstance( "SitemapJobRegistry@sitemap-spider" ).reapStaleJobs();
				if ( recovered > 0 ) {
					variables.log.info( "sitemap-spider: marked #recovered# job(s) interrupted after their process died" );
				}
			} )
			.every( max( 5, variables.moduleSettings.jobReaperIntervalSeconds ), "seconds" )
			.delay( 60, "seconds" )
			.withNoOverlaps()
			// Run only when stale-job recovery is enabled for a shared store.
			.when( function(){
				return variables.moduleSettings.jobReaperEnabled && jobStoreIsShared();
			} )
			.onFailure( function( task, exception ){
				variables.log.error( "sitemap-spider: could not recover dead jobs: #exception.message#", exception );
			} );

		// Disable repeating tasks for a single-server store so ColdBox does not
		// create their timers. Changing jobStoreDsl requires a reinit.
		if ( !scheduleTimerTasks ) {
			progressTask.disable();
			reaperTask.disable();
		}
	}

	/**
	 * shouldScheduleTimerTasks
	 *
	 * Returns whether heartbeat and stale-job tasks need timers. It checks the
	 * store directly so this step does not create the registry's thread pool.
	 * A startup error returns true; each task will check again before it runs.
	 */
	private boolean function shouldScheduleTimerTasks(){
		try {
			return getInstance( variables.moduleSettings.jobStoreDsl ).isShared();
		} catch ( any e ) {
			variables.log.warn(
				"sitemap-spider: could not ask the job store whether it is shared (#e.message#). The background tasks will be scheduled and decide per run instead."
			);
			return true;
		}
	}

	/**
	 * jobStoreIsShared
	 *
	 * Returns whether several app servers share the job store. This method must
	 * not throw: an exception from a ColdBox .when() closure cancels the repeating
	 * task instead of only skipping one run.
	 */
	private boolean function jobStoreIsShared(){
		try {
			return getInstance( "SitemapJobRegistry@sitemap-spider" ).usesSharedStore();
		} catch ( any e ) {
			return false;
		}
	}

}
