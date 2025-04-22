component{

	function configure(){
		setFullRewrites( true );

        route( "create/" ).to( "main.create" ).end();

		route( ":handler/:action?" ).end();
	}

}