/**
 * Defines storage for background sitemap job records.
 *
 * InMemoryJobStore loses records on restart. A durable implementation can save
 * them in a database. CrawlProgress keeps live per-page counters in memory; the
 * store receives status changes and periodic heartbeats. The host owns the
 * record's meta struct, which list() can filter.
 *
 * A job status is queued, running, completed, failed, canceled, or interrupted.
 * Older durable records can omit newer option keys. SitemapJobRegistry uses the
 * matching module setting when a key is missing.
 */
interface {

	/**
	 * isShared
	 *
	 * Returns true only when more than one app server reads this store. This
	 * enables heartbeat and stale-job tasks used to detect another server's crash.
	 */
	boolean function isShared();

	/**
	 * save
	 *
	 * Inserts or replaces a job record. expectedOwnerId must make the read and
	 * write atomic so an old crawl cannot overwrite a re-claimed job.
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
	 * get
	 *
	 * Returns a job record, or an empty struct when the id does not exist.
	 *
	 * @jobId The job's unique id.
	 */
	struct function get( required string jobId );

	/**
	 * list
	 *
	 * Returns records that match every filter value. status accepts one value or
	 * an array. Other keys match the record's meta struct. Order is not guaranteed.
	 *
	 * @filter Optional keys the record must match. Empty returns every job.
	 */
	array function list( struct filter = {} );

	/**
	 * remove
	 *
	 * Removes a job record when it exists.
	 *
	 * @jobId The job's unique id.
	 */
	void function remove( required string jobId );

	/**
	 * claim
	 *
	 * Atomically changes one queued job to running. Only one worker can succeed.
	 * A successful claim saves the owner, node, boot, start time, heartbeat, and
	 * incremented attempt count.
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
	 * heartbeat
	 *
	 * Updates a running job's heartbeat and saved progress.
	 *
	 * @jobId    The running job.
	 * @progress A CrawlProgress snapshot struct.
	 */
	void function heartbeat( required string jobId, required struct progress );

	/**
	 * findStale
	 *
	 * Returns running jobs whose heartbeat is older than staleSeconds. The value
	 * should be several times larger than the heartbeat interval.
	 *
	 * @staleSeconds How old a heartbeat must be before the job counts as dead.
	 */
	array function findStale( required numeric staleSeconds );

	/**
	 * findOrphaned
	 *
	 * Returns running jobs owned by this node but a previous boot. Their crawl
	 * threads ended with that boot.
	 *
	 * @nodeId        This app server's id.
	 * @currentBootId The boot happening now; records with a different one are dead.
	 */
	array function findOrphaned( required string nodeId, required string currentBootId );

}
