/**
 * A job store where every method throws.
 *
 * Tests that shutdown errors do not leave ModuleConfig.onUnload(). ColdBox can
 * delete the application when a module unload handler throws.
 */
component {

	/**
	 * init
	 *
	 * Returns the test store.
	 */
	function init(){
		return this;
	}

	/**
	 * isShared
	 *
	 * Throws the configured test error.
	 */
	boolean function isShared(){
		throw( type = "BrokenJobStore.Failure", message = "isShared failed" );
	}

	/**
	 * save
	 *
	 * Throws the configured test error.
	 */
	boolean function save(
		required string jobId,
		required struct record,
		string expectedOwnerId = ""
	){
		throw( type = "BrokenJobStore.Failure", message = "save failed" );
	}

	/**
	 * get
	 *
	 * Throws the configured test error.
	 */
	struct function get( required string jobId ){
		throw( type = "BrokenJobStore.Failure", message = "get failed" );
	}

	/**
	 * list
	 *
	 * Throws the configured test error.
	 */
	array function list( struct filter = {} ){
		throw( type = "BrokenJobStore.Failure", message = "list failed" );
	}

	/**
	 * remove
	 *
	 * Throws the configured test error.
	 */
	void function remove( required string jobId ){
		throw( type = "BrokenJobStore.Failure", message = "remove failed" );
	}

	/**
	 * claim
	 *
	 * Throws the configured test error.
	 */
	boolean function claim(
		required string jobId,
		required string ownerId,
		required string nodeId,
		required string bootId
	){
		throw( type = "BrokenJobStore.Failure", message = "claim failed" );
	}

	/**
	 * heartbeat
	 *
	 * Throws the configured test error.
	 */
	void function heartbeat( required string jobId, required struct progress ){
		throw( type = "BrokenJobStore.Failure", message = "heartbeat failed" );
	}

	/**
	 * findStale
	 *
	 * Throws the configured test error.
	 */
	array function findStale( required numeric staleSeconds ){
		throw( type = "BrokenJobStore.Failure", message = "findStale failed" );
	}

	/**
	 * findOrphaned
	 *
	 * Throws the configured test error.
	 */
	array function findOrphaned( required string nodeId, required string currentBootId ){
		throw( type = "BrokenJobStore.Failure", message = "findOrphaned failed" );
	}

}
