/**
 * Unit specs for CrawlProgress.cfc.
 *
 * CrawlProgress is a pure counter object (no HTTP, no crawl): the Crawler updates
 * it during a crawl and a caller reads snapshot()/isCanceled(). These specs drive
 * it directly, so no server or fixture is needed beyond WireBox resolving the
 * transient component.
 *
 * Local run recipe:
 *   1. box server start serverConfigFile=server-adobe@2023.json
 *   2. box testbox run runner="http://localhost:61002/tests/runner.cfm" bundles="tests.specs.CrawlProgressSpec"
 */
component extends="coldbox.system.testing.BaseTestCase" appMapping="root" {

	function beforeAll(){
		super.beforeAll();
		setup();
	}

	function afterAll(){
		super.afterAll();
	}

	// A fresh CrawlProgress. It is transient, so getInstance returns a new one.
	private any function newProgress(){
		return getInstance( "CrawlProgress@sitemap-spider" );
	}

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
