/**
 * An in-memory job store that claims to be shared between app servers.
 *
 * Used to check the other half of the isShared() switch. The real
 * InMemoryJobStore says false, which keeps the heartbeat and dead-job tasks
 * switched off; a host pointing jobStoreDsl at a database several servers share
 * says true and expects both tasks to run. Rather than stand up a database for
 * that, this reuses all of InMemoryJobStore's behavior and changes only the one
 * answer the scheduler asks for.
 */
component
	extends="sitemap-spider.models.jobs.InMemoryJobStore"
	hint   ="In-memory job store that reports itself as shared, for testing the scheduler gate"
{

	boolean function isShared(){
		return true;
	}

}
