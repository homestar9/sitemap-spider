component
	singleton
	// threadsafe stops WireBox putting this object in its singleton cache before
	// onDiComplete() has run. Without it, a background task calling getInstance()
	// while another thread is still wiring this one gets a copy that has no store
	// and no progressMap yet, and every method below blows up. Nothing injects
	// this component into anything else, so no circular dependency needs the
	// early publish that dropping this attribute would restore.
	threadsafe
	accessors=true
	hint     ="Runs sitemap crawls as background jobs and tracks their progress"
{

	property name="settings"           inject="coldbox:moduleSettings:sitemap-spider";
	property name="sitemapService"     inject="SitemapService@sitemap-spider";
	property name="asyncManager"       inject="coldbox:asyncManager";
	property name="interceptorService" inject="coldbox:interceptorService";
	property name="logger"             inject="logbox:logger:{this}";
	property name="wirebox"            inject="Wirebox";

	// Statuses a job can no longer move out of.
	variables.terminalStatuses = [
		"completed",
		"failed",
		"canceled",
		"interrupted"
	];

	/**
	 * Initializes the registry. The real setup is in onDiComplete, which runs
	 * after WireBox has filled in the properties above.
	 */
	function init(){
		return this;
	}

	/**
	 * Wires up the parts that need injected dependencies.
	 *
	 * - store: the IJobStore named by the jobStoreDsl setting, so a host can swap
	 *   the in-memory default for one backed by a database.
	 * - executor: a fixed pool sized to maxConcurrentJobs. A fixed pool runs that
	 *   many jobs at once and holds the rest in its own queue, starting them as
	 *   slots free up, which is exactly the behavior wanted here.
	 * - progressMap: the live CrawlProgress for each running job, kept in memory
	 *   so per-page counting never touches the store.
	 * - nodeId / bootId: which app server this is, and which start of it. Both go
	 *   on a job when it is claimed. bootId is what lets the app spot jobs left
	 *   "running" by its own previous start: those threads are gone for certain.
	 */
	function onDiComplete(){
		variables.store    = wirebox.getInstance( settings.jobStoreDsl );
		variables.executor = asyncManager.newExecutor(
			name    = "sitemap-jobs",
			type    = "fixed",
			threads = max( 1, settings.maxConcurrentJobs )
		);
		variables.progressMap = createObject( "java", "java.util.concurrent.ConcurrentHashMap" ).init();

		variables.nodeId  = len( settings.jobNodeId ) ? settings.jobNodeId : resolveHostName();
		variables.bootId  = createUUID();
		variables.ownerId = variables.nodeId & ":" & variables.bootId;
	}

	/**
	 * True once onDiComplete() has run and the store and counters exist.
	 *
	 * The background methods below check this before doing anything. A scheduled
	 * task can fire while WireBox is still building this singleton — right after
	 * a framework reinit, for example — and skipping that tick is the right
	 * answer, because the next one runs against a finished object. Throwing
	 * instead would put a stacktrace in the host's log for something that fixes
	 * itself in seconds.
	 *
	 * The threadsafe attribute on this component should stop that from happening
	 * at all. This is the second line of defence, and it matters because the
	 * scheduler asks usesSharedStore() from a .when() constraint, where ColdBox
	 * does not catch errors — see config/Scheduler.cfc.
	 */
	private boolean function isReady(){
		return variables.keyExists( "store" ) && variables.keyExists( "progressMap" );
	}

	/**
	 * True when the job store is shared between app servers.
	 *
	 * The scheduler asks before each run of the heartbeat and dead-job tasks,
	 * because neither does anything useful for a single server. See
	 * IJobStore.isShared() for what the answer switches on and off.
	 *
	 * Returns false while this object is still being wired, so a task firing
	 * mid-reinit skips its turn rather than throwing.
	 */
	boolean function usesSharedStore(){
		return isReady() && variables.store.isShared();
	}

	/**
	 * Returns the name this app server goes by in job records: the jobNodeId
	 * setting, or the machine's host name when that is empty.
	 */
	string function getNodeId(){
		return variables.nodeId;
	}

	/**
	 * Returns the id for this start of the app. A job record carrying a different
	 * one is left over from a previous start, which is how the startup sweep spots
	 * jobs whose threads are gone.
	 */
	string function getBootId(){
		return variables.bootId;
	}

	/**
	 * Returns the id that marks jobs as belonging to this app server and this
	 * start of it. Useful to a host showing which server is running a job.
	 */
	string function getOwnerId(){
		return variables.ownerId;
	}

	/**
	 * Returns this machine's host name, used to name the app server when the
	 * jobNodeId setting is empty. Falls back to "unknown-host" when the lookup
	 * fails, which only affects how job records are labelled.
	 */
	private string function resolveHostName(){
		try {
			return createObject( "java", "java.net.InetAddress" ).getLocalHost().getHostName();
		} catch ( any e ) {
			return "unknown-host";
		}
	}

	/**
	 * Queues a crawl to run in the background and returns its job id right away.
	 *
	 * The crawl runs on the job thread pool. When every slot is busy the job waits
	 * as "queued" and starts as soon as one frees up.
	 *
	 * filePath is required because a background job has no response to write to,
	 * so it has to save the file for the host to serve or upload later. An empty
	 * one throws sitemap-spider.FilePathRequired.
	 *
	 * runAsync is off by default: the job already has its own pool thread, and
	 * turning it on multiplies threads (maxConcurrentJobs times asyncMaxThreads at
	 * worst). browserDsl picks the backend for this one job, which matters because
	 * each Playwright job runs its own browser process. meta is the host's own
	 * bookkeeping (site id, customer id) — stored as-is, handed back on every read,
	 * usable as a filter in listJobs(), and never read by this module.
	 *
	 * @url            The start URL (string) or array of URLs, as SitemapService.create takes.
	 * @filePath       Required. Where to write the finished sitemap.
	 * @seedUrls       Extra start URLs for pages nothing links to.
	 * @excludeUrls    Exact URLs to skip.
	 * @excludePattern Section-exclude regex for this crawl.
	 * @publicBaseUrl  Absolute URL prefix used in a split sitemap's index entries.
	 * @runAsync       When true, this one crawl fetches on several threads.
	 * @browserDsl     Browser backend for this job. Empty uses the module setting.
	 * @includeImages  Image sitemap extension for this job. Omit to use the setting.
	 * @includeHreflang hreflang extension for this job. Omit to use the setting.
	 * @includeVideos  Video extension for this job. Omit to use the setting.
	 * @writeMetadata  Write the JSON metadata sidecar after the sitemap. Omit to
	 *   use the setting. See SitemapService.create.
	 * @metadataPath   Where to write the sidecar. Omit to use the module setting;
	 *   pass an explicit empty string to derive it from filePath.
	 * @metadataIncludeUrls Carry the full badUrls/ignored lists in the sidecar.
	 *   Omit to use the setting.
	 * @meta           The host's own values to store with the job.
	 *
	 * @return The new job's id.
	 */
	string function queue(
		required any url,
		required string filePath,
		array seedUrls        = [],
		array excludeUrls     = [],
		string excludePattern = "",
		string publicBaseUrl  = "",
		boolean runAsync      = false,
		string browserDsl     = "",
		boolean includeImages,
		boolean includeHreflang,
		boolean includeVideos,
		boolean writeMetadata,
		string metadataPath,
		boolean metadataIncludeUrls,
		struct meta           = {}
	){
		// The extension and metadata flags are resolved here rather than left
		// null, because they are written onto the job record and a store cannot
		// save a null. Resolving at queue time also means the job runs with the
		// settings the caller queued it under, even if a setting changes before
		// its turn.
		param name="arguments.includeImages" default="#settings.includeImages#";
		param name="arguments.includeHreflang" default="#settings.includeHreflang#";
		param name="arguments.includeVideos" default="#settings.includeVideos#";
		param name="arguments.writeMetadata" default="#settings.writeMetadata#";
		// param preserves an explicitly passed empty string, which is the
		// per-job escape hatch back to adjacent-file derivation.
		param name="arguments.metadataPath" default="#settings.metadataPath#";
		param name="arguments.metadataIncludeUrls" default="#settings.metadataIncludeUrls#";

		if ( !len( arguments.filePath ) ) {
			throw(
				type    = "sitemap-spider.FilePathRequired",
				message = "A background sitemap job needs a filePath to write the result to."
			);
		}

		var jobId = createUUID();

		// The live counters for this job, held in memory so getJob can read them
		// while the crawl runs.
		variables.progressMap.put( jobId, wirebox.getInstance( "CrawlProgress@sitemap-spider" ) );

		// Everything create() needs is kept on the record, so the pool thread can
		// rebuild the call from the job id alone. It must not read anything from
		// the request that queued it, because that request is long gone by then.
		var record = {
			"id"             : jobId,
			"status"         : "queued",
			"url"            : arguments.url,
			"filePath"       : arguments.filePath,
			"seedUrls"       : arguments.seedUrls,
			"excludeUrls"    : arguments.excludeUrls,
			"excludePattern" : arguments.excludePattern,
			"publicBaseUrl"  : arguments.publicBaseUrl,
			"runAsync"       : arguments.runAsync,
			"browserDsl"     : arguments.browserDsl,
			"includeImages"  : arguments.includeImages,
			"includeHreflang": arguments.includeHreflang,
			"includeVideos"  : arguments.includeVideos,
			"writeMetadata"  : arguments.writeMetadata,
			"metadataPath"   : arguments.metadataPath,
			"metadataIncludeUrls": arguments.metadataIncludeUrls,
			"meta"           : arguments.meta,
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
			// Reserved so a future version could restart a crawl where it stopped
			// instead of from the beginning. Nothing writes it today.
			"checkpoint"     : ""
		};
		variables.store.save( jobId, record );
		announceJobEvent( "onSitemapJobQueued", jobId, record );

		// Hand the crawl to the pool. The closure deliberately captures only the
		// job id string; the thread looks everything else up from the store.
		variables.executor.submit( function(){
			runJob( jobId );
		} );

		return jobId;
	}

	/**
	 * Runs one queued job on a pool thread.
	 *
	 * Claims the job first. claim() only succeeds for one caller, so a job is
	 * never run twice even if another app server is watching the same store. From
	 * there: crawl, then write down how it ended. A failure is written to the
	 * record rather than only logged, because a job nobody marks as finished would
	 * sit on "running" forever.
	 *
	 * @jobId The job to run.
	 */
	private void function runJob( required string jobId ){
		if (
			!variables.store.claim(
				arguments.jobId,
				variables.ownerId,
				variables.nodeId,
				variables.bootId
			)
		) {
			// Already canceled, removed, or taken by someone else.
			variables.progressMap.remove( arguments.jobId );
			return;
		}

		var record   = variables.store.get( arguments.jobId );
		var progress = variables.progressMap.get( arguments.jobId );
		if ( isNull( progress ) ) {
			progress = wirebox.getInstance( "CrawlProgress@sitemap-spider" );
			variables.progressMap.put( arguments.jobId, progress );
		}
		progress.setStatus( "running" );
		announceJobEvent( "onSitemapJobStarted", arguments.jobId, record );

		var endEvent = "onSitemapJobCompleted";

		try {
			var result = sitemapService.create(
				url             = record.url,
				seedUrls        = record.seedUrls,
				excludeUrls     = record.excludeUrls,
				excludePattern  = record.excludePattern,
				filePath        = record.filePath,
				publicBaseUrl   = record.publicBaseUrl,
				runAsync        = record.runAsync,
				browserDsl      = record.browserDsl,
				// The keys are checked rather than read straight, because a
				// record queued by an older version, or already sitting in a
				// persistent store before an upgrade, will not have them.
				includeImages   = recordFlag( record, "includeImages" ),
				includeHreflang = recordFlag( record, "includeHreflang" ),
				includeVideos   = recordFlag( record, "includeVideos" ),
				writeMetadata   = recordFlag( record, "writeMetadata" ),
				metadataPath    = recordMetadataPath( record ),
				metadataIncludeUrls = recordFlag( record, "metadataIncludeUrls" ),
				progress        = progress
			);

			// A crawl stopped part way through is canceled, not completed.
			var finalStatus = progress.isCanceled() ? "canceled" : "completed";
			record.status   = finalStatus;
			progress.setStatus( finalStatus );
			endEvent = finalStatus == "canceled" ? "onSitemapJobInterrupted" : "onSitemapJobCompleted";

			record.result = {
				"saved"        : result.saved,
				"filePath"     : result.filePath,
				"type"         : result.type,
				"sitemapCount" : result.sitemapCount,
				"stats"        : result.stats,
				"metadataPath" : result.metadataPath,
				"metadataSaved": result.metadataSaved
			};
		} catch ( any e ) {
			record.status = "failed";
			record.error  = e.message;
			progress.setStatus( "failed" );
			endEvent = "onSitemapJobFailed";
			logger.error( "Sitemap job #arguments.jobId# failed: #e.message#", e );
		} finally {
			record.endedAt  = now();
			record.progress = progress.snapshot();

			// Only write if this job is still ours. After a framework reinit an
			// older crawl thread can still be running while the stale-job check has
			// already marked that job interrupted and something else re-claimed it.
			// Matching on ownerId drops that late write instead of undoing the
			// newer state. When nobody re-claimed it, the write goes through and the
			// real result is recorded.
			var applied = variables.store.save( arguments.jobId, record, variables.ownerId );
			variables.progressMap.remove( arguments.jobId );
			if ( applied ) {
				announceJobEvent( endEvent, arguments.jobId, record );
				enforceRetention();
			}
		}
	}

	/**
	 * Reads one of the boolean job flags off a job record, falling back to the
	 * same-named module setting when the record has no such key.
	 *
	 * queue() always writes all of them, so the fallback is only for records
	 * that predate a flag: ones queued by an older version of this module, or
	 * ones a persistent store was already holding when the host upgraded.
	 *
	 * @record The job record.
	 * @key    One of includeImages, includeHreflang, includeVideos,
	 *   writeMetadata, metadataIncludeUrls.
	 */
	private boolean function recordFlag( required struct record, required string key ){
		return arguments.record.keyExists( arguments.key )
			? arguments.record[ arguments.key ]
			: settings[ arguments.key ];
	}

	/**
	 * Reads the snapshotted metadata path from a job record, falling back to the
	 * module setting only for a legacy record that predates the key.
	 *
	 * An existing empty value is returned unchanged because it deliberately means
	 * "derive the sidecar path from filePath", even if the setting later changes.
	 *
	 * @record The persisted job record.
	 */
	private string function recordMetadataPath( required struct record ){
		return arguments.record.keyExists( "metadataPath" )
			? arguments.record.metadataPath
			: settings.metadataPath;
	}

	/**
	 * Writes the current counters of every running job to the store.
	 *
	 * Called on a timer by the module's scheduler. Two things depend on it: a
	 * dashboard can show progress for a job running on another server or one whose
	 * app has since restarted, and findStale() reads the timestamp it writes to
	 * notice jobs whose process died.
	 *
	 * Only jobs running on this server are in progressMap, so this only ever
	 * reports on its own work.
	 *
	 * @return How many jobs were reported on. 0 when this object is not wired yet.
	 */
	numeric function heartbeatRunningJobs(){
		if ( !isReady() ) {
			return 0;
		}

		var count    = 0;
		var iterator = variables.progressMap.entrySet().iterator();
		while ( iterator.hasNext() ) {
			var entry = iterator.next();
			try {
				variables.store.heartbeat( entry.getKey(), entry.getValue().snapshot() );
				count++;
			} catch ( any e ) {
				logger.warn( "Could not record progress for sitemap job #entry.getKey()#: #e.message#" );
			}
		}
		return count;
	}

	/**
	 * Marks jobs whose process died as interrupted.
	 *
	 * Finds running jobs whose last heartbeat is older than jobStaleSeconds. That
	 * only happens when whatever was running them went away without cleaning up: a
	 * killed server, an out-of-memory, a stopped container. Nothing runs in those
	 * cases, so this check is the only way those jobs ever stop looking active.
	 *
	 * @return How many jobs were marked interrupted. 0 when this object is not
	 *   wired yet.
	 */
	numeric function reapStaleJobs(){
		if ( !isReady() ) {
			return 0;
		}

		var count = 0;
		for ( var record in variables.store.findStale( settings.jobStaleSeconds ) ) {
			if ( markInterrupted( record, "no progress reported for #settings.jobStaleSeconds# seconds" ) ) {
				count++;
			}
		}
		return count;
	}

	/**
	 * Marks jobs left "running" by an earlier start of this same app server.
	 *
	 * Those jobs are dead for certain, because their threads went away with the
	 * previous start. Matching on the boot id means they can be cleaned up the
	 * moment the app comes back rather than waiting for their heartbeats to age
	 * out. Run once at startup.
	 *
	 * With the in-memory store this finds nothing, because the records went away
	 * with the restart too.
	 *
	 * @return How many jobs were marked interrupted. 0 when this object is not
	 *   wired yet.
	 */
	numeric function sweepOrphanedJobs(){
		if ( !isReady() ) {
			return 0;
		}

		var count = 0;
		for ( var record in variables.store.findOrphaned( variables.nodeId, variables.bootId ) ) {
			if ( markInterrupted( record, "the app restarted while this job was running" ) ) {
				count++;
			}
		}
		return count;
	}

	/**
	 * Moves one job to interrupted and tells the host about it.
	 *
	 * The write is conditional on the job still belonging to whoever last claimed
	 * it, so two servers both noticing the same dead job cannot both mark it.
	 *
	 * @record The job record to end.
	 * @reason Why it is being ended; stored on the record for the host to show.
	 *
	 * @return true when this call was the one that marked it.
	 */
	private boolean function markInterrupted( required struct record, required string reason ){
		var ended     = arguments.record;
		var claimedBy = ended.ownerId;
		ended.status  = "interrupted";
		ended.endedAt = now();
		ended.error   = arguments.reason;

		if ( !variables.store.save( ended.id, ended, claimedBy ) ) {
			return false;
		}
		variables.progressMap.remove( ended.id );
		logger.warn( "Sitemap job #ended.id# marked interrupted: #arguments.reason#" );
		announceJobEvent( "onSitemapJobInterrupted", ended.id, ended );
		return true;
	}

	/**
	 * Returns one job's current state: its stored record plus a "progress" key.
	 *
	 * For a job running here the progress is live. For one running elsewhere, or
	 * one that has finished, it is the last set of counters written to the store.
	 *
	 * @jobId The job to read. Returns an empty struct when there is no such job.
	 */
	struct function getJob( required string jobId ){
		var record = variables.store.get( arguments.jobId );
		if ( structIsEmpty( record ) ) {
			return {};
		}
		return withProgress( record );
	}

	/**
	 * Returns jobs as record-plus-progress structs, newest first.
	 *
	 * "status" in the filter narrows by status, and takes either one status or an
	 * array of them. Any other key is matched against the job's meta struct, so a
	 * host can ask for one customer's or one site's jobs.
	 *
	 * @filter Optional keys the job must match. Empty returns every job.
	 */
	array function listJobs( struct filter = {} ){
		var out = [];
		for ( var record in variables.store.list( arguments.filter ) ) {
			out.append( withProgress( record ) );
		}
		out.sort( function( a, b ){
			return dateCompare( b.createdAt, a.createdAt );
		} );
		return out;
	}

	/**
	 * Adds a "progress" key to a record: the live counters when the job is running
	 * on this server, otherwise the last ones written to the store.
	 *
	 * @record The stored job record.
	 */
	private struct function withProgress( required struct record ){
		var out           = arguments.record;
		var progress      = variables.progressMap.get( arguments.record.id );
		out[ "progress" ] = isNull( progress ) ? arguments.record.progress : progress.snapshot();
		return out;
	}

	/**
	 * Asks a job to stop.
	 *
	 * A job still waiting in the queue is skipped when its turn comes. A running
	 * one stops after the page it is on finishes, so with the Playwright backend
	 * this can take a few seconds. The job's own thread writes the final status.
	 *
	 * @jobId The job to cancel.
	 *
	 * @return false when there is no such job.
	 */
	boolean function cancel( required string jobId ){
		var record = variables.store.get( arguments.jobId );
		if ( structIsEmpty( record ) ) {
			return false;
		}

		var progress = variables.progressMap.get( arguments.jobId );
		if ( !isNull( progress ) ) {
			progress.cancel();
		}

		// Marking a queued job right away means it shows as canceled immediately
		// and runJob's claim will refuse to start it. A running job's own thread
		// confirms the final status when it stops.
		if ( !arrayContains( variables.terminalStatuses, record.status ) && record.status == "queued" ) {
			record.status  = "canceled";
			record.endedAt = now();
			variables.store.save( arguments.jobId, record );
		}
		return true;
	}

	/**
	 * Removes a job's record and its live counters. Use after downloading the
	 * file, or to clear a finished job out of a list.
	 *
	 * @jobId The job to remove.
	 */
	void function remove( required string jobId ){
		variables.store.remove( arguments.jobId );
		variables.progressMap.remove( arguments.jobId );
	}

	/**
	 * Stops all background jobs, for a framework reinit or app shutdown.
	 *
	 * Cancels every job running here and records it as interrupted. A reinit
	 * replaces every singleton, so without this the crawls would keep going with
	 * nothing tracking them and their jobs would read "running" forever.
	 *
	 * It does not stop the thread pool. ColdBox owns that pool (it is registered
	 * with the async manager as "sitemap-jobs") and stops it as part of the same
	 * reinit, right after this runs. Writing the job records is the part only this
	 * method can do.
	 *
	 * It only cancels; it never closes a crawl's browser itself. A Playwright
	 * browser can only be driven from the thread that created it, so reaching in
	 * from here could hang. The crawl's own thread notices the cancel and closes
	 * its browser as it finishes, which is both safe and enough.
	 *
	 * Nothing in here is allowed to throw: ModuleConfig.onUnload() calls it, and an
	 * error escaping that would make ColdBox tear down the whole application.
	 *
	 * @return How many running jobs were marked interrupted. 0 when this object
	 *   is not wired yet, in which case it never queued anything either.
	 */
	numeric function shutdown(){
		if ( !isReady() ) {
			return 0;
		}

		var count = 0;

		try {
			// Ask every crawl running here to stop at its next page.
			var iterator = variables.progressMap.entrySet().iterator();
			while ( iterator.hasNext() ) {
				var entry = iterator.next();
				try {
					entry.getValue().cancel();
				} catch ( any e ) {
					logger.warn( "Could not cancel sitemap job #entry.getKey()#: #e.message#" );
				}
			}

			// Write them down as interrupted while the store is still reachable.
			// This is the part that matters: the crawl threads may outlive this
			// call, but the records are what a host reads afterwards.
			var running = variables.store.list( { "status" : "running" } );
			for ( var record in running ) {
				try {
					if (
						record.ownerId == variables.ownerId
						&& markInterrupted( record, "the application shut down or reloaded" )
					) {
						count++;
					}
				} catch ( any e ) {
					logger.warn( "Could not mark sitemap job #record.id# interrupted: #e.message#" );
				}
			}
		} catch ( any e ) {
			logger.error( "Error while shutting sitemap jobs down: #e.message#", e );
		}

		return count;
	}

	/**
	 * Tells the host app that a job changed state, if it is listening.
	 *
	 * This is how a host does its own work — uploading the file over FTP or SSH,
	 * emailing someone, counting usage — without this module knowing about any of
	 * it. Announcing an event nobody listens for does nothing, so apps that only
	 * call SitemapService directly are unaffected. A listener that throws must not
	 * take the job down with it, so errors are caught and logged.
	 *
	 * @event  Which point to announce; see interceptorSettings in ModuleConfig.
	 * @jobId  The job the event is about.
	 * @record Its record at that moment.
	 */
	private void function announceJobEvent(
		required string event,
		required string jobId,
		required struct record
	){
		try {
			interceptorService.announce(
				arguments.event,
				{ "jobId" : arguments.jobId, "record" : arguments.record }
			);
		} catch ( any e ) {
			logger.error( "A listener for #arguments.event# threw on job #arguments.jobId#: #e.message#", e );
		}
	}

	/**
	 * Drops the oldest finished jobs once there are more than maxRetainedJobs of
	 * them, so a long-running host does not keep every job it has ever run. Only
	 * finished jobs are dropped; queued and running ones are left alone.
	 */
	private void function enforceRetention(){
		var cap = settings.maxRetainedJobs;
		if ( cap <= 0 ) {
			return;
		}

		var finished = variables.store.list( { "status" : variables.terminalStatuses } );
		if ( finished.len() <= cap ) {
			return;
		}

		finished.sort( function( a, b ){
			return dateCompare( a.endedAt, b.endedAt );
		} );
		var removeCount = finished.len() - cap;
		for ( var i = 1; i <= removeCount; i++ ) {
			remove( finished[ i ].id );
		}
	}

}
