/**
 * Uses in-memory records but reports that multiple app servers share them.
 * Scheduler specs use it to enable heartbeat and stale-job tasks.
 */
component
	extends="sitemap-spider.models.jobs.InMemoryJobStore"
	hint   ="In-memory job store that reports itself as shared for scheduler tests"
{

	/**
	 * isShared
	 *
	 * Returns true so scheduler specs use shared-store tasks.
	 */
	boolean function isShared(){
		return true;
	}

}
