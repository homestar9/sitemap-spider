component{

	/**
	 * configure
	 *
	 * Defines the test harness ColdBox settings.
	 */
	function configure(){

		// Configure the test application.
		coldbox = {
			appName 				= "Module Tester",

			reinitPassword			= "",
			handlersIndexAutoReload = true,
			modulesExternalLocation = [],

			defaultEvent			= "",
			requestStartHandler		= "",
			requestEndHandler		= "",
			applicationStartHandler = "",
			applicationEndHandler	= "",
			sessionStartHandler 	= "",
			sessionEndHandler		= "",
			missingTemplateHandler	= "",

			exceptionHandler		= "",
			onInvalidEvent			= "",
			customErrorTemplate 	= "/coldbox/system/exceptions/Whoops.cfm",

			handlerCaching 			= false,
			eventCaching			= false
		};

		// Treat local hosts as the development environment.
		environments = {
			development = "localhost,127\.0\.0\.1"
		};

		// Load every discovered module.
		modules = {
			include = [],
			exclude = []
		};

		// Keep robots.txt rules enabled but skip its two-second crawl delay.
		// RobotsParserSpec tests the delay calculation separately.
		moduleSettings = {
			"sitemap-spider" : { maxCrawlDelay : 0 }
		};

		// Register interceptors in execution order.
		interceptors = [
		];

		// Send test logs to the console and a rolling file.
		logBox = {
			appenders = {
				myConsole : { class : "ConsoleAppender" },
				files : {
					class="RollingFileAppender",
					properties = {
						filename = "tester", filePath="/#appMapping#/logs"
					}
				}
			},
			root = { levelmax="DEBUG", appenders="*" },
			info = [ "coldbox.system" ]
		};

	}

	/**
	 * afterAspectsLoad
	 *
	 * Registers and activates the module under test.
	 */
	function afterAspectsLoad( event, interceptData, rc, prc ){

		controller.getModuleService()
			.registerAndActivateModule(
				moduleName 		= request.MODULE_NAME,
				invocationPath 	= "moduleroot"
			);
	}

}
