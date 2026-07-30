/**
 * Contract for where sitemap job records are kept.
 *
 * The module ships InMemoryJobStore, which is fine for a single app server and
 * loses everything on a restart. A host that needs job records to survive a
 * restart, or that runs more than one app server against one database, writes
 * its own implementation and points the jobStoreDsl module setting at it.
 *
 * Two things stay OUT of this contract on purpose:
 *
 * 1. Live per-page counters. Those live in memory on the CrawlProgress object.
 *    A store only sees the job's status changes plus a periodic heartbeat, so a
 *    database-backed store handles a handful of writes per job instead of one
 *    per crawled page.
 *
 * 2. Anything about customers or sites. A job record carries an opaque "meta"
 *    struct the host fills in (site id, customer id, whatever it needs). The
 *    engine never reads it; list() can filter on it.
 *
 * A record is a struct with these keys:
 *   id, status, url, filePath, seedUrls, excludeUrls, excludePattern,
 *   publicBaseUrl, runAsync, browserDsl, includeImages, includeHreflang,
 *   includeVideos, writeMetadata, metadataPath, metadataIncludeUrls, meta,
 *   nodeId, bootId, ownerId, createdAt, startedAt, endedAt, heartbeatAt,
 *   attempts, progress, result, error, checkpoint
 *
 * The include* and metadata* keys were added after records first shipped. A
 * store holding records written before that is still valid: the registry falls
 * back to the module settings for a record that has none.
 *
 * status is one of: queued, running, completed, failed, canceled, interrupted.
 * The last four are terminal.
 *
 * isShared() decides whether the module runs its two background timers at all.
 * Say false unless more than one app server reads the same records; see that
 * method for what each answer switches on and off.
 */
interface {

	/**
	 * True when more than one app server can see these records.
	 *
	 * The module asks once per timer tick, and skips both the heartbeat task and
	 * the dead-job task when the answer is false. Neither does anything useful
	 * for a single server: it reads its own live counters straight out of memory
	 * rather than from the store, and it cleans up its own leftover rows at boot
	 * by matching bootId in findOrphaned(). Only another server's crash needs a
	 * heartbeat to notice.
	 *
	 * Say false for a store just one server reaches, even a durable one — a
	 * SQLite file or a database only this app connects to. Say true when several
	 * app servers point at one database and share the job queue between them.
	 *
	 * Answering true when it is not costs a store write per running job every
	 * jobHeartbeatSeconds plus a findStale() query every
	 * jobReaperIntervalSeconds, for no benefit. Answering false when it should
	 * be true means a job left running by a crashed server stays "running" until
	 * that server comes back and its boot sweep clears it.
	 */
	boolean function isShared();

	/**
	 * Saves a job record, inserting it or replacing the one with the same id.
	 *
	 * The registry calls this on status changes only, never per crawled page.
	 *
	 * Passing expectedOwnerId makes the write conditional: it only happens if the
	 * stored record still carries that ownerId. This guards the final write of a
	 * job against a stale one. After a ColdBox reinit an old crawl thread keeps
	 * running and can try to write "completed" long after the job was marked
	 * interrupted and re-claimed by someone else. Matching on ownerId drops that
	 * late write, while a job nobody re-claimed still records its real result.
	 *
	 * @jobId           The job's unique id.
	 * @record          The job record struct.
	 * @expectedOwnerId Only write if the stored ownerId matches. Empty skips the check.
	 *
	 * @return true when the record was written, false when the ownerId no longer matched.
	 */
	boolean function save(
		required string jobId,
		required struct record,
		string expectedOwnerId = ""
	);

	/**
	 * Returns the record for a job id, or an empty struct when there is none.
	 * An empty struct (not null) means callers can read it without a null check.
	 *
	 * @jobId The job's unique id.
	 */
	struct function get( required string jobId );

	/**
	 * Returns job records as an array. The order is not guaranteed; the caller
	 * sorts.
	 *
	 * Every key in the filter must match for a record to come back. "status"
	 * matches the record's status, and accepts either one status or an array of
	 * acceptable ones. Any other key is matched against the record's meta struct,
	 * so a host can ask for one customer's or one site's jobs. An empty filter
	 * returns everything.
	 *
	 * @filter Optional keys the record must match. Empty returns every job.
	 */
	array function list( struct filter = {} );

	/**
	 * Removes a job record. Safe to call for an id that is not there.
	 *
	 * @jobId The job's unique id.
	 */
	void function remove( required string jobId );

	/**
	 * Claims a queued job for one worker, atomically.
	 *
	 * Only the first caller gets true; everyone else gets false. This is what
	 * stops two workers, or two app servers sharing a database, from running the
	 * same job. A store backed by a database does this as a conditional update
	 * ("set status running where id = ? and status = 'queued'") and checks that
	 * one row changed.
	 *
	 * A successful claim sets status to running, stamps ownerId/nodeId/bootId
	 * and startedAt, sets heartbeatAt to now, and adds 1 to attempts.
	 *
	 * @jobId   The job to claim.
	 * @ownerId Identifies the claiming worker: this app server plus this boot.
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
	);

	/**
	 * Records that a running job is still alive, and saves its latest counters.
	 *
	 * Called on a timer (jobHeartbeatSeconds) for every running job. It updates
	 * heartbeatAt and the record's progress struct. Two jobs depend on it: a
	 * dashboard can show progress for a job running on another server or after a
	 * restart, and findStale() uses heartbeatAt to spot jobs whose process died.
	 *
	 * @jobId    The running job.
	 * @progress A CrawlProgress snapshot struct.
	 */
	void function heartbeat( required string jobId, required struct progress );

	/**
	 * Returns running jobs whose heartbeat is older than staleSeconds, meaning
	 * whatever was running them died without cleaning up.
	 *
	 * This is the only thing that catches a hard kill (kill -9, out of memory, a
	 * container stop), because no shutdown code runs in those cases. Keep
	 * staleSeconds several times larger than the heartbeat interval so a slow
	 * garbage collection pause never marks a healthy job dead.
	 *
	 * @staleSeconds How old a heartbeat must be before the job counts as dead.
	 */
	array function findStale( required numeric staleSeconds );

	/**
	 * Returns running jobs claimed by this app server during an earlier boot.
	 *
	 * Those jobs are dead for certain: their threads went away with the previous
	 * boot. Matching on the boot id means the app can clean them up the moment it
	 * starts instead of waiting for their heartbeats to age out.
	 *
	 * An in-memory store always returns an empty array, because its records did
	 * not survive the restart either.
	 *
	 * @nodeId        This app server's id.
	 * @currentBootId The boot happening now; records with a different one are dead.
	 */
	array function findOrphaned( required string nodeId, required string currentBootId );

}
