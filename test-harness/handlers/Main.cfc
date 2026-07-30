/**
 * Handles the test harness home page and sample crawl.
 */
component{

	property name="siteMap" inject="SiteMapService@sitemap-spider";

    
	/**
	 * index
	 *
	 * Renders the test harness home page.
	 */
	any function index( event, rc, prc ){
        event.setView( "main/index" );
	}

    /**
     * create
     *
     * Runs a sample sitemap crawl.
     */
    function create( event, rc, prc ) {

        var wereorganized = "http://127.0.0.1:65475/";
        var ccis = "http://127.0.0.1:62924/";
        
        prc.result = sitemap.create( ccis );

        writeDump( prc.result );

        return "done";

    }

    /**
     * notFound
     *
     * Returns the test harness not-found response.
     */
    function notFound( event, rc, prc ) {
        return "test harness not found"
    }

}
