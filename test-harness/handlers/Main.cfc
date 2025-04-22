/**
* My Event Handler Hint
*/
component{

	property name="siteMap" inject="SiteMap@sitemap-spider";

    
    // Index
	any function index( event, rc, prc ){
        event.setView( "main/index" );
	}

    function create( event, rc, prc ) {

        var wereorganized = "http://127.0.0.1:65475/";
        var ccis = "http://127.0.0.1:62924/";
        
        prc.result = sitemap.create( ccis );

        writeDump( prc.result );

        return "done";

    }

    function notFound( event, rc, prc ) {
        return "test harness not found"
    }

}