component accessors=true hint="Live, thread-safe progress counters for one crawl job" {

	/**
	 * Builds the counters. Everything is a java.util.concurrent.atomic value so
	 * the single-threaded crawl loop and the parallel crawl workers can all read
	 * and update it safely without a lock. The same primitives the async crawl
	 * already uses for pending/pageCount (see Crawler.initAsyncState) are used
	 * here, so this object is safe to hand into either crawl mode.
	 *
	 * A no-arg CrawlProgress is the "no-op" default the Crawler uses when a caller
	 * did not pass one: the increments still run against these atomics, but nobody
	 * reads them, so the overhead is a few atomic adds and existing behavior is
	 * unchanged.
	 */
	function init(){
		variables.pagesFound    = newInt();
		variables.urlsProcessed = newInt();
		variables.badUrls       = newInt();
		// Best-effort gauge of URLs still waiting to be crawled. Set from the
		// queue/frontier size after each item, so it rises and falls during the
		// crawl instead of only counting up.
		variables.remaining     = newInt();
		variables.canceled      = createObject( "java", "java.util.concurrent.atomic.AtomicBoolean" ).init(
			javacast( "boolean", false )
		);
		// Free-text status the registry sets as the job moves through its life:
		// "queued", "running", "completed", "failed", "canceled". Kept here so a
		// live snapshot always carries the status without a second lookup.
		variables.status    = "queued";
		// getTickCount() millis. startTick is set when the crawl actually begins;
		// endTick when it stops. Both 0 until then, so elapsed() can tell "not
		// started" from "finished".
		variables.startTick = 0;
		variables.endTick   = 0;
		return this;
	}

	/** Builds an AtomicInteger seeded at 0. */
	private function newInt(){
		return createObject( "java", "java.util.concurrent.atomic.AtomicInteger" ).init( javacast( "int", 0 ) );
	}

	/** Records one more page written to the sitemap. */
	void function incrementPages(){
		variables.pagesFound.incrementAndGet();
	}

	/** Records one more URL fetched and parsed (claimed as processed). */
	void function incrementProcessed(){
		variables.urlsProcessed.incrementAndGet();
	}

	/** Records one more URL that could not be fetched. */
	void function incrementBad(){
		variables.badUrls.incrementAndGet();
	}

	/**
	 * Sets the "still waiting to crawl" gauge to the current queue/frontier size.
	 *
	 * @count The number of URLs left to crawl.
	 */
	void function setRemaining( required numeric count ){
		variables.remaining.set( javacast( "int", arguments.count ) );
	}

	/** Sets the job status string (see init for the values used). */
	void function setStatus( required string status ){
		variables.status = arguments.status;
	}

	/** Marks the crawl start time. Called once when the crawl begins. */
	void function markStarted(){
		variables.startTick = getTickCount();
	}

	/** Marks the crawl end time. Called once when the crawl stops. */
	void function markEnded(){
		variables.endTick = getTickCount();
	}

	/**
	 * Requests cancellation. The crawl loops check isCanceled() between items and
	 * stop early when this is set, so cancellation takes effect after the URL
	 * currently in flight finishes, not instantly.
	 */
	void function cancel(){
		variables.canceled.set( javacast( "boolean", true ) );
	}

	/** Reports whether cancellation was requested. */
	boolean function isCanceled(){
		return variables.canceled.get();
	}

	/**
	 * Milliseconds the crawl has been running: 0 before it starts, wall-clock so
	 * far while running, and the final total once it has ended.
	 */
	numeric function elapsed(){
		if ( variables.startTick == 0 ) {
			return 0;
		}
		var end = variables.endTick == 0 ? getTickCount() : variables.endTick;
		return end - variables.startTick;
	}

	/**
	 * Returns a plain struct copy of the counters for the dashboard. Reading the
	 * atomics here is a point-in-time sample; a live crawl may have moved on by
	 * the time the caller uses it, which is fine for a progress display.
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
