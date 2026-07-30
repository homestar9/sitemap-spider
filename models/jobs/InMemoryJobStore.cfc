component
	singleton
	implements="IJobStore"
	hint      ="Keeps job records in a thread-safe in-memory map. The default IJobStore."
{

	// Stop a compare-and-swap loop when another thread keeps changing the record.
	variables.maxSwapAttempts = 20;

	/**
	 * init
	 *
	 * Creates the thread-safe record map. Records are shared across requests but
	 * are lost on an application restart. Plain Java map methods are used because
	 * CFML closures do not convert to Java functions on every supported engine.
	 */
	function init(){
		variables.jobs = createObject( "java", "java.util.concurrent.ConcurrentHashMap" ).init();
		return this;
	}

	/**
	 * isShared
	 *
	 * Returns false because only this app server can read the records.
	 */
	boolean function isShared(){
		return false;
	}

	/**
	 * save
	 *
	 * Inserts or replaces a record. expectedOwnerId makes the write conditional
	 * so an old crawl cannot overwrite a job that another worker re-claimed.
	 *
	 * @jobId           The job's unique id.
	 * @record          The job record struct.
	 * @expectedOwnerId Only write if the stored ownerId matches. Empty skips the check.
	 *
	 * @return true when the record was written.
	 */
	boolean function save(
		required string jobId,
		required struct record,
		string expectedOwnerId = ""
	){
		if ( !len( arguments.expectedOwnerId ) ) {
			variables.jobs.put( arguments.jobId, arguments.record );
			return true;
		}

		for ( var attempt = 1; attempt <= variables.maxSwapAttempts; attempt++ ) {
			var stored = variables.jobs.get( arguments.jobId );
			if ( isNull( stored ) || stored.ownerId != arguments.expectedOwnerId ) {
				return false;
			}
			// Replace only the exact record that was just checked.
			if ( variables.jobs.replace( arguments.jobId, stored, arguments.record ) ) {
				return true;
			}
		}
		return false;
	}

	/**
	 * get
	 *
	 * Returns a copy of a record, or an empty struct. The copy prevents callers
	 * from changing stored state by reference.
	 *
	 * @jobId The job's unique id.
	 */
	struct function get( required string jobId ){
		var record = variables.jobs.get( arguments.jobId );
		return isNull( record ) ? {} : duplicate( record );
	}

	/**
	 * list
	 *
	 * Returns copies of matching records. status accepts one value or an array.
	 * Other filter keys match record.meta. Order is not guaranteed.
	 *
	 * @filter Optional keys the record must match. Empty returns every job.
	 */
	array function list( struct filter = {} ){
		var out      = [];
		var iterator = variables.jobs.values().iterator();
		while ( iterator.hasNext() ) {
			var record = iterator.next();
			if ( matchesFilter( record, arguments.filter ) ) {
				out.append( duplicate( record ) );
			}
		}
		return out;
	}

	/**
	 * matchesFilter
	 *
	 * Returns whether a record matches every filter value.
	 *
	 * @record The job record to test.
	 * @filter The filter struct; empty matches everything.
	 */
	private boolean function matchesFilter( required struct record, required struct filter ){
		for ( var key in arguments.filter ) {
			var wanted = arguments.filter[ key ];

			if ( key == "status" ) {
				// Match one status or any status in an array.
				var matched = isArray( wanted )
				 ? wanted.findNoCase( arguments.record.status ) > 0
				 : arguments.record.status == wanted;
				if ( !matched ) {
					return false;
				}
				continue;
			}

			// Match other filter values against the host's meta struct.
			if ( !arguments.record.keyExists( "meta" ) || !isStruct( arguments.record.meta ) ) {
				return false;
			}
			if ( !arguments.record.meta.keyExists( key ) || arguments.record.meta[ key ] != wanted ) {
				return false;
			}
		}
		return true;
	}

	/**
	 * remove
	 *
	 * Removes a job record when it exists.
	 *
	 * @jobId The job's unique id.
	 */
	void function remove( required string jobId ){
		variables.jobs.remove( arguments.jobId );
	}

	/**
	 * claim
	 *
	 * Atomically changes a queued job to running for one worker.
	 *
	 * @jobId   The job to claim.
	 * @ownerId Identifies the claiming worker (app server plus boot).
	 * @nodeId  The app server's id, stored so a boot sweep can find its own rows.
	 * @bootId  This boot's id, stored for the same reason.
	 *
	 * @return true when this caller claimed it.
	 */
	boolean function claim(
		required string jobId,
		required string ownerId,
		required string nodeId,
		required string bootId
	){
		for ( var attempt = 1; attempt <= variables.maxSwapAttempts; attempt++ ) {
			var stored = variables.jobs.get( arguments.jobId );
			if ( isNull( stored ) || stored.status != "queued" ) {
				return false;
			}

			// Change a copy so the stored record remains unchanged until replace succeeds.
			var claimed         = duplicate( stored );
			claimed.status      = "running";
			claimed.ownerId     = arguments.ownerId;
			claimed.nodeId      = arguments.nodeId;
			claimed.bootId      = arguments.bootId;
			claimed.startedAt   = now();
			claimed.heartbeatAt = now();
			claimed.attempts    = claimed.attempts + 1;

			if ( variables.jobs.replace( arguments.jobId, stored, claimed ) ) {
				return true;
			}
		}
		return false;
	}

	/**
	 * heartbeat
	 *
	 * Saves the latest progress and heartbeat. A failed replacement is not retried
	 * because another heartbeat will run soon.
	 *
	 * @jobId    The running job.
	 * @progress A CrawlProgress snapshot struct.
	 */
	void function heartbeat( required string jobId, required struct progress ){
		var stored = variables.jobs.get( arguments.jobId );
		if ( isNull( stored ) ) {
			return;
		}
		var beat         = duplicate( stored );
		beat.heartbeatAt = now();
		beat.progress    = arguments.progress;
		variables.jobs.replace( arguments.jobId, stored, beat );
	}

	/**
	 * findStale
	 *
	 * Returns running jobs whose heartbeat is older than staleSeconds.
	 *
	 * @staleSeconds How old a heartbeat must be before the job counts as dead.
	 */
	array function findStale( required numeric staleSeconds ){
		var out      = [];
		var cutoff   = dateAdd( "s", -arguments.staleSeconds, now() );
		var iterator = variables.jobs.values().iterator();
		while ( iterator.hasNext() ) {
			var record = iterator.next();
			if (
				record.status == "running"
				&& isDate( record.heartbeatAt )
				&& dateCompare( record.heartbeatAt, cutoff ) < 0
			) {
				out.append( duplicate( record ) );
			}
		}
		return out;
	}

	/**
	 * findOrphaned
	 *
	 * Returns an empty array because old records disappear with this in-memory store.
	 *
	 * @nodeId        This app server's id.
	 * @currentBootId The id of the boot happening now.
	 */
	array function findOrphaned( required string nodeId, required string currentBootId ){
		return [];
	}

}
