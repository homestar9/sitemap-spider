/**
 * Runs TestBox specs in a ColdBox virtual application.
 */
component{

	// Identify the module and its source directory.
	request.MODULE_NAME = "sitemap-spider";
	request.MODULE_PATH = "sitemap-spider";

	// Configure the TestBox application.
	this.name 				= "#request.MODULE_NAME# Testing Suite";
	this.sessionManagement 	= true;
	this.sessionTimeout 	= createTimeSpan( 0, 0, 15, 0 );
	this.applicationTimeout = createTimeSpan( 0, 0, 15, 0 );
	this.setClientCookies 	= true;
	// Let the engine remove unnecessary whitespace.
	this.whiteSpaceManagement = "smart";
    this.enableNullSupport = shouldEnableFullNullSupport();

	// Map the tests, application, and module source.
	this.mappings[ "/tests" ] = getDirectoryFromPath( getCurrentTemplatePath() );
	rootPath = REReplaceNoCase( this.mappings[ "/tests" ], "tests(\\|/)", "" );
	this.mappings[ "/root" ]   			= rootPath;
	moduleRootPath = REReplaceNoCase( rootPath, "#request.MODULE_PATH#(\\|/)test-harness(\\|/)", "" );
	this.mappings[ "/moduleroot" ] 				= moduleRootPath;
	this.mappings[ "/#request.MODULE_NAME#" ] 	= moduleRootPath & "#request.MODULE_PATH#";

	// Load Playwright only when the optional test dependency is installed.
	// Specs run in this application, so its classpath must contain the jars.
	this.cbPlaywrightLib = rootPath & "modules/cbPlaywright/lib";
	if ( directoryExists( this.cbPlaywrightLib ) ) {
		this.javaSettings = {
			loadPaths : directoryList( this.cbPlaywrightLib, true, "array", "*.jar" ),
			loadColdFusionClassPath : true,
			reloadOnChange : false
		};
		// Playwright.cfc includes helpers through this mapping.
		this.mappings[ "/cbPlaywright" ] = rootPath & "modules/cbPlaywright";
	}

	/* Optional ORM settings for local test applications.
	this.datasource = "coolblog";
	this.ormEnabled = "true";
	this.ormSettings = {
		cfclocation = [ "/root/models" ],
		logSQL = true,
		dbcreate = "update",
		secondarycacheenabled = false,
		cacheProvider = "ehcache",
		flushAtRequestEnd = false,
		eventhandling = true,
		eventHandler = "cborm.models.EventHandler",
		skipcfcWithError = false
	};
	*/

	/**
	 * onRequestStart
	 *
	 * Starts or restarts the ColdBox virtual application for TestBox requests.
	 */
	function onRequestStart( required targetPage ){

		// Allow enough time for full integration crawls.
		setting requestTimeout="9999";
		request.coldBoxVirtualApp = new coldbox.system.testing.VirtualApp( appMapping = "/root" );

		// Start ColdBox only for the runner and spec requests.
		if ( getBaseTemplatePath().replace( expandPath( "/tests" ), "" ).reFindNoCase( "(runner|specs)" ) ) {
			request.coldBoxVirtualApp.startup();
		}

		// Restart ColdBox when the request asks for a reinit.
		if( structKeyExists( url, "fwreinit" ) ){
			if( structKeyExists( server, "lucee" ) ){
				pagePoolClear();
			}
			// ormReload();
			request.coldBoxVirtualApp.restart();
		}

		return true;
	}

	/**
	 * onRequestEnd
	 *
	 * Ends the TestBox request.
	 */
	public void function onRequestEnd( required targetPage ) {
		request.coldBoxVirtualApp.shutdown();
	}

    /**
     * shouldEnableFullNullSupport
     *
     * Reads the FULL_NULL environment variable to decide this.enableNullSupport.
     *
     * Avoid Java on Lucee and BoxLang. On BoxLang, loading a Java class here
     * before this.javaSettings takes effect prevents the first request from
     * finding Playwright classes. Adobe ColdFusion uses the Java fallback.
     */
    private boolean function shouldEnableFullNullSupport() {
        if ( server.keyExists( "system" ) && server.system.keyExists( "environment" ) ) {
            var envValue = server.system.environment.FULL_NULL ?: "";
            return len( envValue ) ? !!envValue : false;
        }
        var value = createObject( "java", "java.lang.System" ).getEnv( "FULL_NULL" );
        return isNull( value ) ? false : !!value;
    }
}
