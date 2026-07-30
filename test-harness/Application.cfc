/**
 * Runs the browser-based test harness.
 */
component{

	// Module under test.
	request.MODULE_NAME = "sitemap-spider";

	// Configure the test harness application.
	this.name              = hash( getCurrentTemplatePath() );
	this.sessionManagement = true;
	this.sessionTimeout    = createTimeSpan(0,0,15,0);
    this.setClientCookies  = true;

	// Buffer function output so exceptions can include it.
	this.bufferOutput 					= true;
	// Disable response compression in the test harness.
	this.compression 					= false;
	// Let Lucee remove unnecessary whitespace.
	this.whiteSpaceManagement 			= "smart";
	// Keep whitespace in remote component responses.
	this.suppressRemoteComponentContent = false;

	// ColdBox uses these values to locate and name the application.
	COLDBOX_APP_ROOT_PATH       = getDirectoryFromPath( getCurrentTemplatePath() );
	COLDBOX_APP_MAPPING         = "";
	COLDBOX_CONFIG_FILE 	    = "";
	COLDBOX_APP_KEY 		    = "";

	// Map the test harness and module source.
	this.mappings[ "/root" ] = COLDBOX_APP_ROOT_PATH;
	moduleRootPath 	= REReplaceNoCase( this.mappings[ "/root" ], "#request.MODULE_NAME#(\\|/)test-harness(\\|/)", "" );
	modulePath 		= REReplaceNoCase( this.mappings[ "/root" ], "test-harness(\\|/)", "" );
	this.mappings[ "/moduleroot" ] = moduleRootPath;
	this.mappings[ "/#request.MODULE_NAME#" ] = modulePath;

	// Load Playwright only when the optional test dependency is installed.
	this.cbPlaywrightLib = COLDBOX_APP_ROOT_PATH & "modules/cbPlaywright/lib";
	if ( directoryExists( this.cbPlaywrightLib ) ) {
		this.javaSettings = {
			loadPaths : directoryList( this.cbPlaywrightLib, true, "array", "*.jar" ),
			loadColdFusionClassPath : true,
			reloadOnChange : false
		};
		// Playwright.cfc includes helpers through this mapping.
		this.mappings[ "/cbPlaywright" ] = COLDBOX_APP_ROOT_PATH & "modules/cbPlaywright";
	}

	// Optional ORM settings for local test applications.
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

	/**
	 * onApplicationStart
	 *
	 * Starts the ColdBox test harness.
	 */
	public boolean function onApplicationStart(){
		application.cbBootstrap = new coldbox.system.Bootstrap( COLDBOX_CONFIG_FILE, COLDBOX_APP_ROOT_PATH, COLDBOX_APP_KEY, COLDBOX_APP_MAPPING );
		application.cbBootstrap.loadColdbox();
		return true;
	}

	/**
	 * onRequestStart
	 *
	 * Passes the current request to ColdBox.
	 */
	public boolean function onRequestStart(String targetPage){

		if( url.keyExists( "fwreinit" ) ){
			if( server.keyExists( "lucee" ) ){
				pagePoolClear();
			}
			// Reload ORM here when a local test application enables it.
			// ormReload();
		}

		// Pass the request to ColdBox.
		application.cbBootstrap.onRequestStart( arguments.targetPage );

		return true;
	}

	/**
	 * onSessionStart
	 *
	 * Registers a new session with ColdBox.
	 */
	public void function onSessionStart(){
		application.cbBootStrap.onSessionStart();
	}

	/**
	 * onSessionEnd
	 *
	 * Ends a ColdBox session.
	 */
	public void function onSessionEnd( struct sessionScope, struct appScope ){
		arguments.appScope.cbBootStrap.onSessionEnd( argumentCollection=arguments );
	}

	/**
	 * onMissingTemplate
	 *
	 * Lets ColdBox handle a missing template.
	 */
	public boolean function onMissingTemplate( template ){
		return application.cbBootstrap.onMissingTemplate( argumentCollection=arguments );
	}

}
