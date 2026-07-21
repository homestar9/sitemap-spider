/**
********************************************************************************
Copyright 2005-2007 ColdBox Framework by Luis Majano and Ortus Solutions, Corp
www.ortussolutions.com
********************************************************************************
*/
component{

	// UPDATE THE NAME OF THE MODULE IN TESTING BELOW
	request.MODULE_NAME = "sitemap-spider";

	// Application properties
	this.name              = hash( getCurrentTemplatePath() );
	this.sessionManagement = true;
	this.sessionTimeout    = createTimeSpan(0,0,15,0);
    this.setClientCookies  = true;

    /**************************************
	LUCEE Specific Settings
	**************************************/
	// buffer the output of a tag/function body to output in case of a exception
	this.bufferOutput 					= true;
	// Activate Gzip Compression
	this.compression 					= false;
	// Turn on/off white space managemetn
	this.whiteSpaceManagement 			= "smart";
	// Turn on/off remote cfc content whitespace
	this.suppressRemoteComponentContent = false;

	// COLDBOX STATIC PROPERTY, DO NOT CHANGE UNLESS THIS IS NOT THE ROOT OF YOUR COLDBOX APP
	COLDBOX_APP_ROOT_PATH       = getDirectoryFromPath( getCurrentTemplatePath() );
	// The web server mapping to this application. Used for remote purposes or static purposes
	COLDBOX_APP_MAPPING         = "";
	// COLDBOX PROPERTIES
	COLDBOX_CONFIG_FILE 	    = "";
	// COLDBOX APPLICATION KEY OVERRIDE
	COLDBOX_APP_KEY 		    = "";

    // Mappings
	this.mappings[ "/root" ] = COLDBOX_APP_ROOT_PATH;

	// Map back to its root
	moduleRootPath 	= REReplaceNoCase( this.mappings[ "/root" ], "#request.MODULE_NAME#(\\|/)test-harness(\\|/)", "" );
	modulePath 		= REReplaceNoCase( this.mappings[ "/root" ], "test-harness(\\|/)", "" );

	// Module Root + Path Mappings
	this.mappings[ "/moduleroot" ] = moduleRootPath;
	this.mappings[ "/#request.MODULE_NAME#" ] = modulePath;

	// Load the cbPlaywright Java jars (Playwright + its driver bundle) onto the
	// CF class path so the Playwright browser backend can create a Playwright
	// instance. Guarded by directoryExists so this is a no-op when cbPlaywright
	// is not installed (it is an optional, test-only dependency). A real host app
	// that uses the Playwright backend must load these jars the same way.
	this.cbPlaywrightLib = COLDBOX_APP_ROOT_PATH & "modules/cbPlaywright/lib";
	if ( directoryExists( this.cbPlaywrightLib ) ) {
		this.javaSettings = {
			loadPaths : directoryList( this.cbPlaywrightLib, true, "array", "*.jar" ),
			loadColdFusionClassPath : true,
			reloadOnChange : false
		};
	}

	// ORM definitions: ENABLE IF NEEDED
	//this.datasource = "coolblog";
	//this.ormEnabled = "true";
	/**
	this.ormSettings = {
		cfclocation = [ "models" ],
		logSQL = true,
		dbcreate = "update",
		secondarycacheenabled = false,
		cacheProvider = "ehcache",
		flushAtRequestEnd = false,
		eventhandling = true,
		eventHandler = "cborm.models.EventHandler",
		skipcfcWithError = true
	};
	**/

	// application start
	public boolean function onApplicationStart(){
		application.cbBootstrap = new coldbox.system.Bootstrap( COLDBOX_CONFIG_FILE, COLDBOX_APP_ROOT_PATH, COLDBOX_APP_KEY, COLDBOX_APP_MAPPING );
		application.cbBootstrap.loadColdbox();
		return true;
	}

	// request start
	public boolean function onRequestStart(String targetPage){

		if( url.keyExists( "fwreinit" ) ){
			if( server.keyExists( "lucee" ) ){
				pagePoolClear();
			}
			// ORM reload: ENABLE IF NEEDED
			// ormReload();
		}

		// Process ColdBox Request
		application.cbBootstrap.onRequestStart( arguments.targetPage );

		return true;
	}

	public void function onSessionStart(){
		application.cbBootStrap.onSessionStart();
	}

	public void function onSessionEnd( struct sessionScope, struct appScope ){
		arguments.appScope.cbBootStrap.onSessionEnd( argumentCollection=arguments );
	}

	public boolean function onMissingTemplate( template ){
		return application.cbBootstrap.onMissingTemplate( argumentCollection=arguments );
	}

}
