/**
 * Specs for the module's background upkeep tasks in config/Scheduler.cfc.
 *
 * These cover three problems a host app hit, all of them showing up as a
 * stacktrace in the log for something that was not really broken:
 *
 * 1. Right after a framework reinit, a task could fetch a SitemapJobRegistry
 *    that WireBox had not finished wiring, so it had no store and no
 *    progressMap yet.
 * 2. The .onFailure() handlers called err(), which belongs to ScheduledTask and
 *    not to a scheduler, so a task failure threw a second error on top of the
 *    first.
 * 3. The heartbeat and dead-job tasks ran on a timer forever even with the
 *    default in-memory store, where neither can accomplish anything.
 *
 * Nothing here waits for a real timer to fire. The tasks are inspected directly:
 * isConstrained() reports whether a task would skip its next turn, isDisabled()
 * plus an empty task record "future" shows it was never handed to the executor at
 * all, and getOnTaskFailure() hands back the closure ColdBox would call on a
 * failure.
 *
 * Local run recipe:
 *   1. box server start serverConfigFile=server-lucee@6.json
 *   2. box testbox run runner="http://localhost:61002/tests/runner.cfm" bundles="tests.specs.SchedulerSpec"
 */
component extends="coldbox.system.testing.BaseTestCase" appMapping="root" {

	// The scheduler ColdBox builds from config/Scheduler.cfc for this module.
	variables.schedulerName = "cbScheduler@sitemap-spider";

	variables.timerTasks = [
		"sitemap-spider:record-job-progress",
		"sitemap-spider:recover-dead-jobs"
	];
	variables.bootTask = "sitemap-spider:recover-interrupted-jobs";

	function beforeAll(){
		super.beforeAll();
		setup();
	}

	function afterAll(){
		super.afterAll();
	}

	/** Returns the module's scheduler object. */
	private any function scheduler(){
		return getInstance( variables.schedulerName );
	}

	/** Returns one registered task by name. */
	private any function taskNamed( required string name ){
		return scheduler().getTaskRecord( arguments.name ).task;
	}

	/**
	 * True when ColdBox actually handed this task to the executor.
	 *
	 * startupTask() fills in the record's "future" only for a task it schedules,
	 * and returns early for a disabled one, so an empty future means nothing is
	 * ever going to wake for it.
	 *
	 * @name The task to check.
	 */
	private boolean function isScheduled( required string name ){
		var record = scheduler().getTaskRecord( arguments.name );
		return isObject( record.future );
	}

	/**
	 * Swaps the registry's store for the duration of one test, then always puts
	 * the real one back. The registry is a singleton the rest of the suite shares,
	 * so leaving a test double behind would break later specs.
	 *
	 * @store The store to use.
	 * @body  Called with the registry once the swap is in place.
	 */
	private void function withStore( required any store, required any body ){
		var registry  = prepareMock( getInstance( "SitemapJobRegistry@sitemap-spider" ) );
		var realStore = registry.$getProperty( "store", "variables" );
		registry.$property(
			propertyName  = "store",
			propertyScope = "variables",
			mock          = arguments.store
		);
		try {
			arguments.body( registry );
		} finally {
			registry.$property(
				propertyName  = "store",
				propertyScope = "variables",
				mock          = realStore
			);
		}
	}

	function run(){
		describe( "a registry WireBox has not finished wiring", function(){
			// WireBox puts a singleton in its cache before wiring it unless the
			// component says threadsafe, so a task firing during a reinit could get
			// an object whose onDiComplete() had not run. Building one without
			// onDiComplete() reproduces exactly that object.
			function halfBuilt(){
				return createObject( "component", "sitemap-spider.models.jobs.SitemapJobRegistry" ).init();
			}

			it( "reports no shared store instead of throwing", function(){
				expect( halfBuilt().usesSharedStore() ).toBeFalse();
			} );

			it( "skips the heartbeat rather than erroring", function(){
				expect( halfBuilt().heartbeatRunningJobs() ).toBe( 0 );
			} );

			it( "skips the dead-job check rather than erroring", function(){
				expect( halfBuilt().reapStaleJobs() ).toBe( 0 );
			} );

			it( "skips the boot sweep rather than erroring", function(){
				expect( halfBuilt().sweepOrphanedJobs() ).toBe( 0 );
			} );

			it( "shuts down cleanly, having never queued anything", function(){
				expect( halfBuilt().shutdown() ).toBe( 0 );
			} );
		} );

		describe( "task failure handlers", function(){
			// ScheduledTask.run() has already logged the real error by the time it
			// calls one of these. A handler that throws adds a second, misleading
			// stacktrace, which is what err() used to do from in here.
			it( "log the failure without throwing a second error", function(){
				var tasks = [ variables.bootTask ];
				tasks.append( variables.timerTasks, true );
				for ( var name in tasks ) {
					var task    = taskNamed( name );
					var handler = task.getOnTaskFailure();
					expect( isClosure( handler ) || isCustomFunction( handler ) ).toBeTrue(
						"#name# should have a failure handler"
					);
					expect( function(){
						handler( task, { "message" : "test failure" } );
					} ).notToThrow( message = "#name# failure handler threw" );
				}
			} );
		} );

		describe( "with the default in-memory store", function(){
			it( "reports itself as not shared", function(){
				expect( getInstance( "InMemoryJobStore@sitemap-spider" ).isShared() ).toBeFalse();
			} );

			it( "holds both timer tasks back, because neither could achieve anything", function(){
				for ( var name in variables.timerTasks ) {
					expect( taskNamed( name ).isConstrained() ).toBeTrue(
						"#name# should not run against an unshared store"
					);
				}
			} );

			// The check above only proves a task would skip its turn. This one
			// proves it never gets a turn: ColdBox returns early for a disabled task
			// in startupTask(), before it calls start(), so nothing is handed to the
			// executor and no thread ever wakes on the interval.
			it( "never hands either timer task to the executor", function(){
				for ( var name in variables.timerTasks ) {
					expect( taskNamed( name ).isDisabled() ).toBeTrue( "#name# should be disabled at load time" );
					expect( isScheduled( name ) ).toBeFalse( "#name# should never have been scheduled" );
				}
			} );

			it( "still lets the once-per-boot sweep run", function(){
				// This one is what a durable single-server store needs, and it costs
				// one call per boot, so it is never gated.
				expect( taskNamed( variables.bootTask ).isConstrained() ).toBeFalse();
				expect( taskNamed( variables.bootTask ).isDisabled() ).toBeFalse();
				expect( isScheduled( variables.bootTask ) ).toBeTrue();
			} );
		} );

		describe( "with a store shared between app servers", function(){
			it( "lets both timer tasks run", function(){
				withStore( new tests.resources.SharedJobStore(), function( registry ){
					expect( registry.usesSharedStore() ).toBeTrue();
					for ( var name in variables.timerTasks ) {
						expect( taskNamed( name ).isConstrained() ).toBeFalse(
							"#name# should run against a shared store"
						);
					}
				} );
			} );

			it( "records a running job's progress when the heartbeat runs", function(){
				var shared = new tests.resources.SharedJobStore();
				withStore( shared, function( registry ){
					var jobId    = createUUID();
					var progress = getInstance( "CrawlProgress@sitemap-spider" );
					progress.setStatus( "running" );
					progress.incrementPages();

					shared.save(
						jobId,
						{
							"id"          : jobId,
							"status"      : "running",
							"ownerId"     : registry.getOwnerId(),
							"heartbeatAt" : "",
							"progress"    : {},
							"meta"        : {}
						}
					);

					// Put the job in the live counters map the heartbeat reads from,
					// the same way queue() does.
					var progressMap = registry.$getProperty( "progressMap", "variables" );
					progressMap.put( jobId, progress );
					try {
						expect( registry.heartbeatRunningJobs() ).toBeGTE( 1 );

						var stored = shared.get( jobId );
						expect( isDate( stored.heartbeatAt ) ).toBeTrue();
						expect( stored.progress.pagesFound ).toBe( 1 );
					} finally {
						progressMap.remove( jobId );
					}
				} );
			} );
		} );

		describe( "a job store having a bad day", function(){
			// ColdBox evaluates a .when() closure outside the try/catch in
			// ScheduledTask.run(). An error escaping it reaches the scheduled
			// executor, which cancels the task permanently instead of skipping one
			// turn. So a store that throws has to read as a plain "no".
			it( "holds the timer tasks back instead of killing them off", function(){
				withStore( new tests.resources.BrokenJobStore(), function( registry ){
					for ( var name in variables.timerTasks ) {
						var task = taskNamed( name );
						expect( function(){
							task.isConstrained();
						} ).notToThrow( message = "#name# constraint threw" );
						expect( task.isConstrained() ).toBeTrue();
					}
				} );
			} );
		} );
	}

}
