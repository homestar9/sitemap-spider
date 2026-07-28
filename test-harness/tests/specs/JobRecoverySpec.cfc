/**
 * Specs for how sitemap jobs recover when something goes wrong.
 *
 * These cover the parts that only matter when a crawl does not finish normally:
 * claiming a job so it never runs twice, spotting jobs whose process died,
 * cleaning up after a restart, and shutting down on a framework reinit.
 *
 * Nothing here really kills a server. The failure modes are driven straight
 * through the job store instead — backdating a heartbeat, writing a record from a
 * different boot — which is both faster and repeatable.
 *
 * InMemoryJobStore is exercised directly for the store-level rules. The registry
 * specs use a stub store so a fake "dead" job can be planted without running a
 * real crawl.
 *
 * Local run recipe:
 *   1. box server start serverConfigFile=server-adobe@2023.json
 *   2. box testbox run runner="http://localhost:61002/tests/runner.cfm" bundles="tests.specs.JobRecoverySpec"
 */
component extends="coldbox.system.testing.BaseTestCase" appMapping="root" {

	function beforeAll(){
		super.beforeAll();
		setup();
	}

	function afterAll(){
		super.afterAll();
	}

	// A fresh, empty in-memory store, so each spec starts clean. The app treats
	// it as a singleton, so getInstance() would hand back a shared one. The path
	// is passed as a string because the "-" in "sitemap-spider" would be read as
	// a minus sign in the dotted form.
	private any function newStore(){
		return createObject( "component", "sitemap-spider.models.jobs.InMemoryJobStore" ).init();
	}

	/**
	 * Builds a job record with sensible defaults, matching the shape
	 * SitemapJobRegistry.queue() writes.
	 *
	 * @overrides Keys to change on the record, e.g. { status : "running" }.
	 */
	private struct function buildRecord( struct overrides = {} ){
		var record = {
			"id"             : createUUID(),
			"status"         : "queued",
			"url"            : "http://example.test/",
			"filePath"       : "/tmp/sitemap.xml",
			"seedUrls"       : [],
			"excludeUrls"    : [],
			"excludePattern" : "",
			"publicBaseUrl"  : "",
			"runAsync"       : false,
			"browserDsl"     : "",
			"includeImages"  : false,
			"includeHreflang": false,
			"includeVideos"  : false,
			"meta"           : {},
			"nodeId"         : "",
			"bootId"         : "",
			"ownerId"        : "",
			"createdAt"      : now(),
			"startedAt"      : "",
			"endedAt"        : "",
			"heartbeatAt"    : "",
			"attempts"       : 0,
			"progress"       : {},
			"result"         : {},
			"error"          : "",
			"checkpoint"     : ""
		};
		for ( var key in arguments.overrides ) {
			record[ key ] = arguments.overrides[ key ];
		}
		return record;
	}

	function run(){
		describe( "InMemoryJobStore claiming", function(){
			it( "lets exactly one caller claim a queued job", function(){
				var store  = newStore();
				var record = buildRecord();
				store.save( record.id, record );

				expect( store.claim( record.id, "owner-a", "nodeA", "boot1" ) ).toBeTrue();
				// A second worker, or a second app server, must not get it too.
				expect( store.claim( record.id, "owner-b", "nodeB", "boot9" ) ).toBeFalse();

				var claimed = store.get( record.id );
				expect( claimed.status ).toBe( "running" );
				expect( claimed.ownerId ).toBe( "owner-a" );
				expect( claimed.attempts ).toBe( 1 );
				expect( isDate( claimed.startedAt ) ).toBeTrue();
				expect( isDate( claimed.heartbeatAt ) ).toBeTrue();
			} );

			it( "refuses to claim a job that is not queued", function(){
				var store  = newStore();
				var record = buildRecord( { "status" : "canceled" } );
				store.save( record.id, record );

				expect( store.claim( record.id, "owner-a", "nodeA", "boot1" ) ).toBeFalse();
			} );

			it( "refuses to claim a job that is not there", function(){
				expect( newStore().claim( "no-such-job", "owner-a", "nodeA", "boot1" ) ).toBeFalse();
			} );
		} );

		describe( "InMemoryJobStore ownerId-guarded writes", function(){
			// This is the race after a framework reinit: an old crawl thread is
			// still running and tries to write its result, but the job has since
			// been marked dead and re-claimed by someone else. The late write has
			// to lose.
			it( "rejects a write from an owner that no longer holds the job", function(){
				var store  = newStore();
				var record = buildRecord();
				store.save( record.id, record );
				store.claim( record.id, "owner-old", "nodeA", "boot1" );

				// Something re-claims it (as the reaper path would, after marking it).
				var reclaimed    = store.get( record.id );
				reclaimed.status = "queued";
				store.save( record.id, reclaimed );
				store.claim( record.id, "owner-new", "nodeA", "boot2" );

				// The old thread finally finishes and tries to record success.
				var late    = store.get( record.id );
				late.status = "completed";
				expect( store.save( record.id, late, "owner-old" ) ).toBeFalse();
				expect( store.get( record.id ).status ).toBe( "running" );
			} );

			it( "accepts a write from the owner that still holds the job", function(){
				var store  = newStore();
				var record = buildRecord();
				store.save( record.id, record );
				store.claim( record.id, "owner-a", "nodeA", "boot1" );

				var done    = store.get( record.id );
				done.status = "completed";
				expect( store.save( record.id, done, "owner-a" ) ).toBeTrue();
				expect( store.get( record.id ).status ).toBe( "completed" );
			} );

			it( "hands back copies so a caller cannot change stored state by accident", function(){
				var store  = newStore();
				var record = buildRecord();
				store.save( record.id, record );

				var read    = store.get( record.id );
				read.status = "completed";

				expect( store.get( record.id ).status ).toBe( "queued" );
			} );
		} );

		describe( "InMemoryJobStore finding dead jobs", function(){
			it( "finds a running job whose progress stopped being reported", function(){
				var store  = newStore();
				var record = buildRecord( {
					"status"      : "running",
					// Last heard from five minutes ago.
					"heartbeatAt" : dateAdd( "n", -5, now() )
				} );
				store.save( record.id, record );

				expect( store.findStale( 90 ).len() ).toBe( 1 );
				// Still within the allowed gap, so not dead yet.
				expect( store.findStale( 3600 ).len() ).toBe( 0 );
			} );

			it( "leaves a job that reported progress just now alone", function(){
				var store  = newStore();
				var record = buildRecord( { "status" : "running", "heartbeatAt" : now() } );
				store.save( record.id, record );

				expect( store.findStale( 90 ).len() ).toBe( 0 );
			} );

			it( "ignores finished jobs when looking for dead ones", function(){
				var store  = newStore();
				var record = buildRecord( {
					"status"      : "completed",
					"heartbeatAt" : dateAdd( "n", -5, now() )
				} );
				store.save( record.id, record );

				expect( store.findStale( 90 ).len() ).toBe( 0 );
			} );

			it( "heartbeat records the counters and refreshes the timestamp", function(){
				var store  = newStore();
				var record = buildRecord( {
					"status"      : "running",
					"heartbeatAt" : dateAdd( "n", -5, now() )
				} );
				store.save( record.id, record );

				store.heartbeat( record.id, { "pagesFound" : 7 } );

				var beaten = store.get( record.id );
				expect( beaten.progress.pagesFound ).toBe( 7 );
				expect( store.findStale( 90 ).len() ).toBe( 0 );
			} );

			it( "finds nothing orphaned, because its records die with the app", function(){
				var store  = newStore();
				var record = buildRecord( {
					"status" : "running",
					"nodeId" : "nodeA",
					"bootId" : "boot1"
				} );
				store.save( record.id, record );

				// A durable store would return this record; an in-memory one cannot,
				// because a real restart would have emptied it too.
				expect( store.findOrphaned( "nodeA", "boot2" ) ).toBeEmpty();
			} );
		} );

		describe( "InMemoryJobStore filtering", function(){
			it( "filters by a single status and by a list of them", function(){
				var store = newStore();
				var a     = buildRecord( { "status" : "queued" } );
				var b     = buildRecord( { "status" : "running" } );
				var c     = buildRecord( { "status" : "completed" } );
				store.save( a.id, a );
				store.save( b.id, b );
				store.save( c.id, c );

				expect( store.list().len() ).toBe( 3 );
				expect( store.list( { "status" : "running" } ).len() ).toBe( 1 );
				expect( store.list( { "status" : [ "queued", "completed" ] } ).len() ).toBe( 2 );
			} );

			it( "filters on the host's meta keys", function(){
				var store = newStore();
				var mine  = buildRecord( { "meta" : { "customerId" : "acme" } } );
				var other = buildRecord( { "meta" : { "customerId" : "globex" } } );
				store.save( mine.id, mine );
				store.save( other.id, other );

				var acme = store.list( { "customerId" : "acme" } );
				expect( acme.len() ).toBe( 1 );
				expect( acme[ 1 ].id ).toBe( mine.id );
			} );
		} );

		describe( "SitemapJobRegistry recovery", function(){
			// Points the registry at a store this spec controls, so a job can be
			// planted as "already dead" without running a real crawl. The registry
			// is a singleton shared with the rest of the suite, so its real store
			// is always put back, even when the spec fails.
			function withStubStore( required any body ){
				var registry  = prepareMock( getInstance( "SitemapJobRegistry@sitemap-spider" ) );
				var realStore = registry.$getProperty( "store", "variables" );
				var stub      = newStore();
				registry.$property(
					propertyName  = "store",
					propertyScope = "variables",
					mock          = stub
				);
				try {
					arguments.body( registry, stub );
				} finally {
					registry.$property(
						propertyName  = "store",
						propertyScope = "variables",
						mock          = realStore
					);
				}
			}

			it( "marks a job interrupted once its process stops reporting progress", function(){
				withStubStore( function( registry, store ){
					var record = buildRecord( {
						"status"      : "running",
						"ownerId"     : "someone-else",
						"heartbeatAt" : dateAdd( "n", -10, now() ),
						"attempts"    : 1
					} );
					store.save( record.id, record );

					expect( registry.reapStaleJobs() ).toBe( 1 );

					var reaped = store.get( record.id );
					expect( reaped.status ).toBe( "interrupted" );
					expect( isDate( reaped.endedAt ) ).toBeTrue();
					expect( len( reaped.error ) ).toBeGT( 0 );

					// Already interrupted, so a second pass finds nothing to do.
					expect( registry.reapStaleJobs() ).toBe( 0 );
				} );
			} );

			it( "leaves a healthy running job alone", function(){
				withStubStore( function( registry, store ){
					var record = buildRecord( { "status" : "running", "heartbeatAt" : now() } );
					store.save( record.id, record );

					expect( registry.reapStaleJobs() ).toBe( 0 );
					expect( store.get( record.id ).status ).toBe( "running" );
				} );
			} );

			it( "reports nothing to recover at startup with the in-memory store", function(){
				withStubStore( function( registry, store ){
					// findOrphaned always comes back empty here, so the boot sweep is
					// a no-op. It must still run cleanly rather than error.
					expect( registry.sweepOrphanedJobs() ).toBe( 0 );
				} );
			} );

			it( "records this server's running jobs as interrupted on shutdown", function(){
				withStubStore( function( registry, store ){
					var record = buildRecord();
					store.save( record.id, record );
					// Claim it as this registry would, so shutdown recognizes it as
					// its own work.
					store.claim(
						record.id,
						registry.getOwnerId(),
						registry.getNodeId(),
						registry.getBootId()
					);

					expect( registry.shutdown() ).toBe( 1 );
					expect( store.get( record.id ).status ).toBe( "interrupted" );
				} );
			} );

			it( "leaves another server's running jobs alone on shutdown", function(){
				withStubStore( function( registry, store ){
					var record = buildRecord( {
						"status"      : "running",
						"ownerId"     : "another-server:another-boot",
						"heartbeatAt" : now()
					} );
					store.save( record.id, record );

					expect( registry.shutdown() ).toBe( 0 );
					expect( store.get( record.id ).status ).toBe( "running" );
				} );
			} );

			// ModuleConfig.onUnload() calls shutdown(). An error escaping that would
			// make ColdBox delete the whole application, so it must swallow anything
			// the store throws.
			it( "never throws when the job store fails during shutdown", function(){
				var registry  = prepareMock( getInstance( "SitemapJobRegistry@sitemap-spider" ) );
				var realStore = registry.$getProperty( "store", "variables" );
				var broken    = new tests.resources.BrokenJobStore();
				registry.$property(
					propertyName  = "store",
					propertyScope = "variables",
					mock          = broken
				);
				try {
					expect( function(){
						registry.shutdown();
					} ).notToThrow();
				} finally {
					registry.$property(
						propertyName  = "store",
						propertyScope = "variables",
						mock          = realStore
					);
				}
			} );
		} );
	}

}
