component extends="coldbox.system.testing.BaseTestCase" appMapping="root" {

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
                
                var sitemap = getInstance( "siteMap@sitemap-spider" );
                sitemap.create( "https://www.ccisbonds.com" );

            });

		} );
	}

}
