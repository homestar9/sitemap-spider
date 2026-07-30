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
 * scheduler methods (task, getInstance, setTimezone) and a LogBox logger as
 * `log` when it loads it, and injects moduleSettings so the tasks can read this
 * module's own settings. Use `variables.log` to report from a task. The `out()`
 * and `err()` helpers people reach for first belong to ScheduledTask, not to a
 * scheduler, and calling them from in here throws.
 *
 * Three tasks:
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
 *
 * Tasks 2 and 3 only apply when the job store is shared between app servers,
 * which the store itself reports through IJobStore.isShared(). The default
 * in-memory store says no, and then neither task is even handed to the executor:
 * nothing is scheduled and no thread ever wakes for them. Task 1 always runs; it
 * costs one call per boot and is what a durable single-server store needs.
 */
component {

	/**
	 * Registers the upkeep tasks. Called once when ColdBox loads this scheduler.
	 */
	function configure(){
		// Asked once, here, rather than only per tick. See disable() at the bottom
		// of this method for what it saves.
		var scheduleTimerTasks = shouldScheduleTimerTasks();

		// Runs once, a little after boot rather than during it, so a slow job
		// store never holds up the first request. No repeat interval, so it fires
		// a single time.
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
			// Nothing is running this soon after a boot, and staying out of the way
			// while the app is still assembling keeps the log clean through a reinit.
			.delay( 30, "seconds" )
			// Waits for one run to finish before starting the next, so a slow store
			// cannot stack these up.
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
			// Two conditions. The store has to be shared, or there is nothing this
			// could ever find. On top of that jobReaperEnabled lets a host switch it
			// off through module settings alone, for example when something outside
			// the app handles cleanup.
			.when( function(){
				return variables.moduleSettings.jobReaperEnabled && jobStoreIsShared();
			} )
			.onFailure( function( task, exception ){
				variables.log.error( "sitemap-spider: could not recover dead jobs: #exception.message#", exception );
			} );

		/*
		 * Turn the two timer tasks off completely for a store only this server
		 * reads, which is the normal case.
		 *
		 * This is not the same as the .when() checks above. ColdBox skips a
		 * disabled task in Scheduler.startupTask() before it ever calls start(),
		 * so a disabled task is never handed to the executor at all: no scheduled
		 * future, no thread waking every 30 seconds to decide it has nothing to
		 * do. The .when() checks stay because they cover the shared-store case and
		 * the jobReaperEnabled switch, and they cost nothing once a task is not
		 * scheduled.
		 *
		 * The trade-off is that this reads the store once at load time, so
		 * changing jobStoreDsl needs a reinit to take effect. Changing a module
		 * setting needs one anyway.
		 */
		if ( !scheduleTimerTasks ) {
			progressTask.disable();
			reaperTask.disable();
		}
	}

	/**
	 * Whether to hand the heartbeat and dead-job tasks to the executor at all.
	 *
	 * Asks the configured job store directly rather than going through
	 * SitemapJobRegistry, so that loading this module does not build the registry
	 * and its thread pool for a host that never queues a job. Building the store
	 * on its own is cheap; the default one just creates an empty map.
	 *
	 * Returns true when the store cannot be built this early — a host's
	 * database-backed store whose connection pool is not up yet, say. Failing to
	 * answer must not stop the module loading, and scheduling the tasks is the
	 * safe way to be wrong: the per-tick .when() check then decides instead, and
	 * that one skips its turn quietly.
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
	 * True when the job store is shared between app servers, which is the only
	 * time the two timer tasks have anything to do.
	 *
	 * This never throws, and that is the whole point of wrapping it. ColdBox
	 * evaluates a .when() closure inside ScheduledTask.isConstrained(), which it
	 * calls before — and outside — the try/catch in ScheduledTask.run(). An error
	 * escaping from here would reach the scheduled executor, and a periodic Java
	 * task that throws is cancelled: this task would stop for good, silently,
	 * rather than skipping one turn. So a registry that is still being wired, or a
	 * store having a bad day, has to read as a plain "no".
	 */
	private boolean function jobStoreIsShared(){
		try {
			return getInstance( "SitemapJobRegistry@sitemap-spider" ).usesSharedStore();
		} catch ( any e ) {
			return false;
		}
	}

}
