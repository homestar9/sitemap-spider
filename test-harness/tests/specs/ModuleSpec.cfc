component extends="coldbox.system.testing.BaseTestCase" appMapping="root" {

	variables.serverRoot = "http#( CGI.HTTPS == "on" ? 's' : '' )#://" & CGI.HTTP_HOST & "/";

    variables.testData = {
        validPages = [
            "",
            "about/",
            "contact.cfm",
            "privacy.cfm"
        ],
        ignoredPages = [
            "/disallow.cfm",
            "/nofollow.cfm"
        ]
        

    }
    
    /*********************************** LIFE CYCLE Methods ***********************************/

	function beforeAll(){
		super.beforeAll();
		setup();
	}

	function afterAll(){
		super.afterAll();
	}

	/*********************************** BDD SUITES ***********************************/

	function run(){
		describe( "Sitemap Tets", function(){
			beforeEach( function( currentSpec ){
			} );

            
            it( "Can load a website", function(){
                
                var sitemapService = getInstance( "sitemapService@sitemap-spider" );
                var appRoot = variables.serverRoot & "tests/resources/sample-site/";
                var result = sitemapService.create( appRoot );

                debug( appRoot );

                debug( result );

                expect( result ).toBeStruct();
                expect( result ).toHaveKey( "pages,badUrls,processedUrls,duration" );

                // Expect valid pages to be in the sitemap
                for( var page in testData.validPages ){
                    expect( result.pages ).toHaveKey( appRoot & page );
                }

                expect( false ).toBeTrue( true );

            });

		} );
	}

}
