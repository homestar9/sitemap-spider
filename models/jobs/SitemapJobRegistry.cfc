component
	singleton
	// Wait until onDiComplete() finishes before WireBox publishes this singleton.
	// A scheduled task must not receive an instance without its store or counters.
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

	// Jobs cannot leave these final statuses.
	variables.terminalStatuses = [
		"completed",
		"failed",
		"canceled",
		"interrupted"
	];

	/**
	 * init
	 *
	 * Returns the registry before injected dependencies are available.
	 */
	function init(){
		return this;
	}

	/**
	 * onDiComplete
	 *
	 * Loads the job store, creates the fixed job pool and live progress map, and
	 * assigns IDs for this server and application start.
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
	 * isReady
	 *
	 * Returns whether onDiComplete() created the store and progress map. Scheduled
	 * tasks skip a run while WireBox rebuilds this singleton.
	 */
	private boolean function isReady(){
		return variables.keyExists( "store" ) && variables.keyExists( "progressMap" );
	}

	/**
	 * usesSharedStore
	 *
	 * Returns whether several app servers share the job store. Returns false
	 * before dependency injection finishes.
	 */
	boolean function usesSharedStore(){
		return isReady() && variables.store.isShared();
	}

	/**
	 * getNodeId
	 *
	 * Returns this app server's job record ID.
	 */
	string function getNodeId(){
		return variables.nodeId;
	}

	/**
	 * getBootId
	 *
	 * Returns the ID for this application start.
	 */
	string function getBootId(){
		return variables.bootId;
	}

	/**
	 * getOwnerId
	 *
	 * Returns the combined node and boot ID used to own claimed jobs.
	 */
	string function getOwnerId(){
		return variables.ownerId;
	}

	/**
	 * resolveHostName
	 *
	 * Returns the machine host name, or "unknown-host" when lookup fails.
	 */
	private string function resolveHostName(){
		try {
			return createObject( "java", "java.net.InetAddress" ).getLocalHost().getHostName();
		} catch ( any e ) {
			return "unknown-host";
		}
	}

	/**
	 * queue
	 *
	 * Saves and queues a background crawl, then returns its job ID. filePath is
	 * required because the job has no HTTP response where it can return XML.
	 *
	 * @url Starting URL or URL array.
	 * @filePath Full path for the saved sitemap.
	 * @seedUrls Extra starting URLs.
	 * @excludeUrls Exact URLs to skip.
	 * @excludePattern Regex for skipped URL sections.
	 * @publicBaseUrl URL prefix used in a split sitemap index.
	 * @runAsync Enables parallel workers inside this job.
	 * @browserDsl Browser backend for this job.
	 * @includeImages Enables image entries.
	 * @includeHreflang Enables hreflang entries.
	 * @includeVideos Enables video entries.
	 * @writeMetadata Saves a JSON metadata file.
	 * @metadataPath Full metadata path. Empty derives it from filePath.
	 * @metadataIncludeUrls Adds badUrls and ignored to metadata.
	 * @meta Host-owned values saved with the job.
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
		// Save concrete option values so later setting changes do not affect this job.
		param name="arguments.includeImages" default="#settings.includeImages#";
		param name="arguments.includeHreflang" default="#settings.includeHreflang#";
		param name="arguments.includeVideos" default="#settings.includeVideos#";
		param name="arguments.writeMetadata" default="#settings.writeMetadata#";
		// Preserve an explicit empty path so it still means "beside the sitemap."
		param name="arguments.metadataPath" default="#settings.metadataPath#";
		param name="arguments.metadataIncludeUrls" default="#settings.metadataIncludeUrls#";

		if ( !len( arguments.filePath ) ) {
			throw(
				type    = "sitemap-spider.FilePathRequired",
				message = "A background sitemap job needs a filePath to write the result to."
			);
		}

		var jobId = createUUID();

		// Keep live counters in memory while the job runs.
		variables.progressMap.put( jobId, wirebox.getInstance( "CrawlProgress@sitemap-spider" ) );

		// Save every create() argument because the original request ends before the job.
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
			// This key is currently always empty.
			"checkpoint"     : ""
		};
		variables.store.save( jobId, record );
		announceJobEvent( "onSitemapJobQueued", jobId, record );

		// Capture only jobId. The worker reads all other values from the store.
		variables.executor.submit( function(){
			runJob( jobId );
		} );

		return jobId;
	}

	/**
	 * runJob
	 *
	 * Claims and runs one queued job, then saves its final status and result.
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
				// Older durable records may not contain newer option keys.
				includeImages   = recordFlag( record, "includeImages" ),
				includeHreflang = recordFlag( record, "includeHreflang" ),
				includeVideos   = recordFlag( record, "includeVideos" ),
				writeMetadata   = recordFlag( record, "writeMetadata" ),
				metadataPath    = recordMetadataPath( record ),
				metadataIncludeUrls = recordFlag( record, "metadataIncludeUrls" ),
				progress        = progress
			);

			// A canceled crawl is not completed.
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

			// ownerId prevents an old crawl from overwriting a re-claimed job.
			var applied = variables.store.save( arguments.jobId, record, variables.ownerId );
			variables.progressMap.remove( arguments.jobId );
			if ( applied ) {
				announceJobEvent( endEvent, arguments.jobId, record );
				enforceRetention();
			}
		}
	}

	/**
	 * recordFlag
	 *
	 * Returns a saved boolean option or its module default for an older record.
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
	 * recordMetadataPath
	 *
	 * Returns a job's metadata path or the module default for an older record.
	 * An existing empty value still means "derive from filePath."
	 *
	 * @record The persisted job record.
	 */
	private string function recordMetadataPath( required struct record ){
		return arguments.record.keyExists( "metadataPath" )
			? arguments.record.metadataPath
			: settings.metadataPath;
	}

	/**
	 * heartbeatRunningJobs
	 *
	 * Saves progress and a heartbeat for jobs running on this server.
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
	 * reapStaleJobs
	 *
	 * Marks jobs interrupted when their heartbeat is older than jobStaleSeconds.
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
	 * sweepOrphanedJobs
	 *
	 * Marks running jobs from an earlier boot of this node interrupted. Their
	 * crawl threads ended when that application stopped.
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
	 * markInterrupted
	 *
	 * Conditionally marks a claimed job interrupted and announces the change.
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
	 * getJob
	 *
	 * Returns a job record with live or last-saved progress.
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
	 * listJobs
	 *
	 * Returns matching jobs with progress, newest first.
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
	 * withProgress
	 *
	 * Adds live progress when available, otherwise the last saved progress.
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
	 * cancel
	 *
	 * Requests cancellation. A running job stops after its current page finishes.
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

		// Cancel a queued job now so runJob() cannot claim it later.
		if ( !arrayContains( variables.terminalStatuses, record.status ) && record.status == "queued" ) {
			record.status  = "canceled";
			record.endedAt = now();
			variables.store.save( arguments.jobId, record );
		}
		return true;
	}

	/**
	 * remove
	 *
	 * Removes a job record and its live progress.
	 *
	 * @jobId The job to remove.
	 */
	void function remove( required string jobId ){
		variables.store.remove( arguments.jobId );
		variables.progressMap.remove( arguments.jobId );
	}

	/**
	 * shutdown
	 *
	 * Cancels this server's jobs and records them as interrupted during shutdown.
	 * ColdBox stops the job pool. Each crawl thread closes its own browser because
	 * Playwright resources must be closed by their creating thread. This method
	 * must not throw because ModuleConfig.onUnload() calls it.
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
			// Ask every local crawl to stop after its current page.
			var iterator = variables.progressMap.entrySet().iterator();
			while ( iterator.hasNext() ) {
				var entry = iterator.next();
				try {
					entry.getValue().cancel();
				} catch ( any e ) {
					logger.warn( "Could not cancel sitemap job #entry.getKey()#: #e.message#" );
				}
			}

			// Save interrupted statuses while the store is still available.
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
	 * announceJobEvent
	 *
	 * Announces a job state change. Listener errors are logged and cannot fail the job.
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
	 * enforceRetention
	 *
	 * Removes the oldest final job records above maxRetainedJobs.
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
