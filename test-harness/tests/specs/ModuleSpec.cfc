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
                
                var sitemapService = getInstance( "sitemapService@sitemap-spider" );
                var result = sitemapService.create( "http://127.0.0.1:62923/" );

                debug( result );

                expect( false ).toBeTrue( true );

            });

		} );
	}

}
