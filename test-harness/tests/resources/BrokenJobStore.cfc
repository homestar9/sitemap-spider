/**
 * A job store where every method throws.
 *
 * Used to prove SitemapJobRegistry.shutdown() cannot throw. ModuleConfig's
 * onUnload() calls shutdown() during a framework reinit, and an error escaping
 * onUnload() makes ColdBox delete the whole application — so a job store having a
 * bad day (a dropped database connection, say) must not be able to take the app
 * down with it.
 *
 * It does not declare implements="IJobStore" because that interface lives in the
 * module's models/jobs folder and no mapping reaches it from here. Matching the
 * method names is enough for the registry, which only calls them.
 */
component {

	function init(){
		return this;
	}

	boolean function isShared(){
		throw( type = "BrokenJobStore.Failure", message = "isShared failed" );
	}

	boolean function save(
		required string jobId,
		required struct record,
		string expectedOwnerId = ""
	){
		throw( type = "BrokenJobStore.Failure", message = "save failed" );
	}

	struct function get( required string jobId ){
		throw( type = "BrokenJobStore.Failure", message = "get failed" );
	}

	array function list( struct filter = {} ){
		throw( type = "BrokenJobStore.Failure", message = "list failed" );
	}

	void function remove( required string jobId ){
		throw( type = "BrokenJobStore.Failure", message = "remove failed" );
	}

	boolean function claim(
		required string jobId,
		required string ownerId,
		required string nodeId,
		required string bootId
	){
		throw( type = "BrokenJobStore.Failure", message = "claim failed" );
	}

	void function heartbeat( required string jobId, required struct progress ){
		throw( type = "BrokenJobStore.Failure", message = "heartbeat failed" );
	}

	array function findStale( required numeric staleSeconds ){
		throw( type = "BrokenJobStore.Failure", message = "findStale failed" );
	}

	array function findOrphaned( required string nodeId, required string currentBootId ){
		throw( type = "BrokenJobStore.Failure", message = "findOrphaned failed" );
	}

}
