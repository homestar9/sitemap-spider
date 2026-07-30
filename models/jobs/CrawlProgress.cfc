component accessors=true hint="Live, thread-safe progress counters for one crawl job" {

	/**
	 * init
	 *
	 * Creates thread-safe counters that both crawl modes can update.
	 */
	function init(){
		variables.pagesFound    = newInt();
		variables.urlsProcessed = newInt();
		variables.badUrls       = newInt();
		// Approximate URLs still waiting or being processed.
		variables.remaining     = newInt();
		variables.canceled      = createObject( "java", "java.util.concurrent.atomic.AtomicBoolean" ).init(
			javacast( "boolean", false )
		);
		// SitemapJobRegistry updates this status as the job changes state.
		variables.status    = "queued";
		// Tick values are 0 before their matching lifecycle event.
		variables.startTick = 0;
		variables.endTick   = 0;
		return this;
	}

	/**
	 * newInt
	 *
	 * Builds an AtomicInteger seeded at 0.
	 */
	private function newInt(){
		return createObject( "java", "java.util.concurrent.atomic.AtomicInteger" ).init( javacast( "int", 0 ) );
	}

	/**
	 * incrementPages
	 *
	 * Records one more page written to the sitemap.
	 */
	void function incrementPages(){
		variables.pagesFound.incrementAndGet();
	}

	/**
	 * incrementProcessed
	 *
	 * Adds one to the processed URL count.
	 */
	void function incrementProcessed(){
		variables.urlsProcessed.incrementAndGet();
	}

	/**
	 * incrementBad
	 *
	 * Records one more URL that could not be fetched.
	 */
	void function incrementBad(){
		variables.badUrls.incrementAndGet();
	}

	/**
	 * setRemaining
	 *
	 * Sets the approximate number of URLs still in the crawl.
	 *
	 * @count The number of URLs left to crawl.
	 */
	void function setRemaining( required numeric count ){
		variables.remaining.set( javacast( "int", arguments.count ) );
	}

	/**
	 * setStatus
	 *
	 * Sets the current job status.
	 */
	void function setStatus( required string status ){
		variables.status = arguments.status;
	}

	/**
	 * markStarted
	 *
	 * Records when the crawl started.
	 */
	void function markStarted(){
		variables.startTick = getTickCount();
	}

	/**
	 * markEnded
	 *
	 * Records when the crawl ended.
	 */
	void function markEnded(){
		variables.endTick = getTickCount();
	}

	/**
	 * cancel
	 *
	 * Requests cancellation. The current fetch finishes before the crawl stops.
	 */
	void function cancel(){
		variables.canceled.set( javacast( "boolean", true ) );
	}

	/**
	 * isCanceled
	 *
	 * Returns whether cancellation was requested.
	 */
	boolean function isCanceled(){
		return variables.canceled.get();
	}

	/**
	 * elapsed
	 *
	 * Returns elapsed milliseconds, or 0 before the crawl starts.
	 */
	numeric function elapsed(){
		if ( variables.startTick == 0 ) {
			return 0;
		}
		var end = variables.endTick == 0 ? getTickCount() : variables.endTick;
		return end - variables.startTick;
	}

	/**
	 * snapshot
	 *
	 * Returns a point-in-time copy of the progress values.
	 */
	struct function snapshot(){
		return {
			"status"        : variables.status,
			"pagesFound"    : variables.pagesFound.get(),
			"urlsProcessed" : variables.urlsProcessed.get(),
			"badUrls"       : variables.badUrls.get(),
			"remaining"     : variables.remaining.get(),
			"canceled"      : variables.canceled.get(),
			"elapsedMs"     : elapsed()
		};
	}

}
