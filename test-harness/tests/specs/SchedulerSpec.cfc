/**
 * Tests startup recovery, progress heartbeats, stale-job recovery, and task
 * failure handlers. The examples inspect task state without waiting for timers.
 */
component extends="coldbox.system.testing.BaseTestCase" appMapping="root" {

	// The scheduler ColdBox builds from config/Scheduler.cfc for this module.
	variables.schedulerName = "cbScheduler@sitemap-spider";

	variables.timerTasks = [
		"sitemap-spider:record-job-progress",
		"sitemap-spider:recover-dead-jobs"
	];
	variables.bootTask = "sitemap-spider:recover-interrupted-jobs";

	/**
	 * beforeAll
	 *
	 * Loads the shared dependencies and fixtures for these specs.
	 */
	function beforeAll(){
		super.beforeAll();
		setup();
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
	 * scheduler
	 *
	 * Returns the module's scheduler object.
	 */
	private any function scheduler(){
		return getInstance( variables.schedulerName );
	}

	/**
	 * taskNamed
	 *
	 * Returns one registered task by name.
	 */
	private any function taskNamed( required string name ){
		return scheduler().getTaskRecord( arguments.name ).task;
	}

	/**
	 * isScheduled
	 *
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
	 * withStore
	 *
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

	/**
	 * run
	 *
	 * Defines the SchedulerSpec examples.
	 */
	function run(){
		describe( "a registry before WireBox finishes dependency injection", function(){
			// WireBox can cache this singleton before onDiComplete() runs.
			// Build that state to test a scheduler task during a reinit.
			/**
			 * halfBuilt
			 *
			 * Returns a registry whose dependency injection is incomplete.
			 */
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
			// Failure handlers must not replace the original error with a new one.
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

			// Disabled tasks must not receive a scheduled executor thread.
			it( "never hands either timer task to the executor", function(){
				for ( var name in variables.timerTasks ) {
					expect( taskNamed( name ).isDisabled() ).toBeTrue( "#name# should be disabled at load time" );
					expect( isScheduled( name ) ).toBeFalse( "#name# should never have been scheduled" );
				}
			} );

			it( "still lets the once-per-boot sweep run", function(){
				// Durable single-server stores still need startup recovery.
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
			// An error from .when() cancels the scheduled task permanently.
			// A store error must therefore make the condition return false.
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
