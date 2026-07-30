/**
 * Tests thread-safe crawl counters, elapsed time, snapshots, and cancellation.
 */
component extends="coldbox.system.testing.BaseTestCase" appMapping="root" {

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
	 * newProgress
	 *
	 * Returns a new CrawlProgress for one example.
	 */
	private any function newProgress(){
		return getInstance( "CrawlProgress@sitemap-spider" );
	}

	/**
	 * run
	 *
	 * Defines the CrawlProgressSpec examples.
	 */
	function run(){
		describe( "CrawlProgress", function(){
			it( "starts at zero with a queued status and no cancel", function(){
				var p    = newProgress();
				var snap = p.snapshot();
				expect( snap.pagesFound ).toBe( 0 );
				expect( snap.urlsProcessed ).toBe( 0 );
				expect( snap.badUrls ).toBe( 0 );
				expect( snap.remaining ).toBe( 0 );
				expect( snap.status ).toBe( "queued" );
				expect( snap.canceled ).toBeFalse();
				expect( p.isCanceled() ).toBeFalse();
			} );

			it( "counts pages, processed URLs, and bad URLs", function(){
				var p = newProgress();
				p.incrementPages();
				p.incrementPages();
				p.incrementProcessed();
				p.incrementProcessed();
				p.incrementProcessed();
				p.incrementBad();

				var snap = p.snapshot();
				expect( snap.pagesFound ).toBe( 2 );
				expect( snap.urlsProcessed ).toBe( 3 );
				expect( snap.badUrls ).toBe( 1 );
			} );

			it( "tracks the remaining gauge as a settable value", function(){
				var p = newProgress();
				p.setRemaining( 12 );
				expect( p.snapshot().remaining ).toBe( 12 );
				p.setRemaining( 0 );
				expect( p.snapshot().remaining ).toBe( 0 );
			} );

			it( "sets and reports the status string", function(){
				var p = newProgress();
				p.setStatus( "running" );
				expect( p.snapshot().status ).toBe( "running" );
			} );

			it( "flips the cancel flag when cancel() is called", function(){
				var p = newProgress();
				expect( p.isCanceled() ).toBeFalse();
				p.cancel();
				expect( p.isCanceled() ).toBeTrue();
				expect( p.snapshot().canceled ).toBeTrue();
			} );

			it( "reports zero elapsed before it starts", function(){
				var p = newProgress();
				expect( p.elapsed() ).toBe( 0 );
				expect( p.snapshot().elapsedMs ).toBe( 0 );
			} );

			it( "reports a non-negative elapsed once started, and freezes it when ended", function(){
				var p = newProgress();
				p.markStarted();
				sleep( 15 );
				var running = p.elapsed();
				expect( running ).toBeGTE( 0 );
				p.markEnded();
				var ended = p.elapsed();
				sleep( 15 );
				// Once ended, elapsed no longer grows.
				expect( p.elapsed() ).toBe( ended );
			} );
		} );
	}

}
