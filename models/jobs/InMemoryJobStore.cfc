component
	singleton
	implements="IJobStore"
	hint      ="Keeps job records in a thread-safe in-memory map. The default IJobStore."
{

	// How many times a compare-and-swap will retry before giving up. Contention
	// is only ever a handful of job threads, so this is never reached in
	// practice; it exists so a pathological race cannot spin forever.
	variables.maxSwapAttempts = 20;

	/**
	 * Builds the backing map.
	 *
	 * A java.util.concurrent.ConcurrentHashMap is used rather than a CFML struct
	 * because several job threads read and write it at once, and because its
	 * replace( key, oldValue, newValue ) swaps a record only if nobody changed it
	 * first. That check-and-swap is what claim() is built on.
	 *
	 * Only plain-argument Java methods are used here (get, put, replace, remove).
	 * The map's compute()/merge() methods would be a shorter way to write the
	 * same thing, but they take a Java function object, and CFML closures do not
	 * convert to those reliably on all three supported engines.
	 *
	 * This is a singleton, so records live as long as the app does and are shared
	 * across requests. They do NOT survive a server restart or a ColdBox reinit,
	 * which builds a fresh singleton. Point the jobStoreDsl setting at a
	 * database-backed IJobStore when records must outlive the app.
	 */
	function init(){
		variables.jobs = createObject( "java", "java.util.concurrent.ConcurrentHashMap" ).init();
		return this;
	}

	/**
	 * Always false: these records live in one app server's memory, so no other
	 * server can see them.
	 *
	 * That answer switches off the heartbeat and dead-job timers, which is
	 * correct here rather than merely cheap. A heartbeat only exists so another
	 * server can watch a job, and getJob() reads this server's own counters
	 * live from memory instead. The dead-job check could never find anything
	 * either: a record only goes stale when the heartbeat task stops, and that
	 * task shares an executor with the dead-job task, so both stop together.
	 */
	boolean function isShared(){
		return false;
	}

	/**
	 * Inserts or replaces the record for a job id.
	 *
	 * With expectedOwnerId passed, the record is only written if the stored one
	 * still carries that ownerId, and the check plus the write happen as one
	 * step. That is what stops a late write from an old crawl thread (one that
	 * outlived a ColdBox reinit) from overwriting a job another worker has since
	 * re-claimed.
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
			// Swaps only when the stored record is still the one just read, so a
			// claim that lands in between makes this fail and re-check instead of
			// overwriting it.
			if ( variables.jobs.replace( arguments.jobId, stored, arguments.record ) ) {
				return true;
			}
		}
		return false;
	}

	/**
	 * Returns a copy of the record for a job id, or an empty struct when absent.
	 *
	 * A copy, not the stored struct itself: CFML structs are handed around by
	 * reference, so returning the real one would let a caller change stored state
	 * just by editing what it read. That would also defeat the ownerId check in
	 * save(), which compares against what is actually in the map.
	 *
	 * @jobId The job's unique id.
	 */
	struct function get( required string jobId ){
		var record = variables.jobs.get( arguments.jobId );
		return isNull( record ) ? {} : duplicate( record );
	}

	/**
	 * Returns copies of the records matching the filter, or of all of them when
	 * the filter is empty. Order is not guaranteed; the caller sorts.
	 *
	 * "status" matches the record's status, and accepts either one status or an
	 * array of acceptable ones. Any other key is matched against the record's meta
	 * struct, so a host can ask for one customer's or one site's jobs.
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
	 * Reports whether a record satisfies every key in the filter.
	 *
	 * @record The job record to test.
	 * @filter The filter struct; empty matches everything.
	 */
	private boolean function matchesFilter( required struct record, required struct filter ){
		for ( var key in arguments.filter ) {
			var wanted = arguments.filter[ key ];

			if ( key == "status" ) {
				// A string matches one status; an array matches any of several.
				var matched = isArray( wanted )
				 ? wanted.findNoCase( arguments.record.status ) > 0
				 : arguments.record.status == wanted;
				if ( !matched ) {
					return false;
				}
				continue;
			}

			// Every other key is a lookup into the host's opaque meta struct.
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
	 * Removes a job record. Does nothing when the id is not there.
	 *
	 * @jobId The job's unique id.
	 */
	void function remove( required string jobId ){
		variables.jobs.remove( arguments.jobId );
	}

	/**
	 * Claims a queued job for one worker.
	 *
	 * Reads the record, builds a changed copy, then swaps the copy in only if
	 * nobody else changed the record first. Two workers racing for the same job
	 * both read status "queued", but only one swap succeeds; the loser re-reads,
	 * sees "running", and returns false. So exactly one caller ever gets true.
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

			// Change a copy, never the stored struct: editing in place would
			// apply the claim before the swap decided whether it was allowed.
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
	 * Marks a running job as still alive and stores its latest counters.
	 *
	 * Best effort: if the record changes while this is running, the update is
	 * dropped rather than retried, because another heartbeat follows shortly and
	 * a missed one changes nothing.
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
	 * Returns running jobs whose heartbeat is older than staleSeconds, meaning
	 * whatever was running them died without cleaning up.
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
	 * Always returns an empty array.
	 *
	 * Orphan detection looks for running jobs left behind by an earlier boot of
	 * this app server. This store keeps records in memory, so they went away with
	 * the boot that created them and there is nothing left to find. A
	 * database-backed store is where this method does real work.
	 *
	 * @nodeId        This app server's id.
	 * @currentBootId The id of the boot happening now.
	 */
	array function findOrphaned( required string nodeId, required string currentBootId ){
		return [];
	}

}
