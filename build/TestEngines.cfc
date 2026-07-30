/**
 * Runs the whole test suite on every engine, one after another.
 *
 * Run it with: box run-script test:engines
 *
 * Do this before a release. It is deliberately not part of the release itself: an engine that
 * fails to start should not stop a publish, and the release already runs the suite once on
 * whichever engine is up.
 *
 * Every engine shares the same port, so this runs strictly in order: stop everything, start
 * one engine, wait for it to answer, run the suite, stop it, move to the next. Expect it to
 * take a while. The first run of an engine also downloads it, which takes longer still.
 *
 * List your engines in build/build.json. Put the ones you trust first: the run stops at the
 * first failure, so a problem with a rarely used engine still leaves you results for the rest.
 */
component {

	/**
	 * init
	 *
	 * Loads the settings.
	 */
	function init(){
		variables.config = new BuildConfig( getDirectoryFromPath( getCurrentTemplatePath() ) );
		variables.s      = variables.config.getSettings();
		return this;
	}

	/**
	 * run
	 *
	 * Runs the suite on each engine in turn. Stops at the first failure, naming the engine that
	 * failed and listing what already passed. Leaves every server stopped either way.
	 */
	function run(){
		if ( !arrayLen( variables.s.engines ) ) {
			return fail(
				"No engines are listed in build/build.json.",
				[
					'"engines": [',
					'    { "name": "Lucee 5",    "configFile": "server-lucee@5.json" },',
					'    { "name": "Adobe 2023", "configFile": "server-adobe@2023.json" }',
					']',
					"",
					"Each configFile is a server json file in your project root.",
					"Put the engines you trust first: the run stops at the first failure."
				],
				"Add them to build/build.json like this"
			);
		}

		var passed  = [];
		var started = getTickCount();

		// Only one server can hold the port, and we do not know which one is up.
		stopAllEngines();

		for ( var engine in variables.s.engines ) {
			var engineName  = engine.name ?: engine.configFile;
			var engineStart = getTickCount();
			print.line().boldBlueLine( "=== #engineName# (#engine.configFile#) ===" ).toConsole();

			startEngine( engine, engineName, passed );
			warmUp( engine, engineName, passed );

			print.blueLine( "Running the suite on #engineName#..." ).toConsole();
			var suiteFailed = false;
			try {
				command( "testbox run" )
					.params( runner = variables.s.testRunner, verbose = false )
					.run();
				suiteFailed = ( shell.getExitCode() != 0 );
			} catch ( any e ) {
				suiteFailed = true;
			}

			stopEngine( engine.configFile );

			if ( suiteFailed ) {
				return failSweep( "The suite FAILED on #engineName#.", passed );
			}

			var minutes = numberFormat( ( getTickCount() - engineStart ) / 60000, "0.9" );
			passed.append( "#engineName# (#minutes# min)" );
			print.boldGreenLine( "#engineName#: passed in #minutes# min." ).toConsole();
		}

		var totalMinutes = numberFormat( ( getTickCount() - started ) / 60000, "0.9" );
		print
			.line()
			.boldGreenLine( "All engines passed in #totalMinutes# min: #passed.toList( ', ' )#" )
			.toConsole();
	}

	/********************************************* PRIVATE HELPERS *********************************************/

	/**
	 * startEngine
	 *
	 * Starts one engine's server and stops the run if the start itself fails.
	 *
	 * @engine     The engine entry from build.json.
	 * @engineName The name to show.
	 * @passed     What already passed, for the failure summary.
	 */
	private function startEngine( required struct engine, required string engineName, required array passed ){
		// Make sure the port is actually free first. Stopping a server returns before the old
		// process lets go of the port, and starting the next one then fails for a reason that
		// has nothing to do with the engine.
		waitForPortToFree( arguments.engineName );

		var startFailed = false;
		var startError  = "";
		try {
			command( "server start" )
				.params( serverConfigFile = arguments.engine.configFile )
				.run();
			startFailed = ( shell.getExitCode() != 0 );
		} catch ( any e ) {
			startFailed = true;
			startError  = e.message;
		}
		if ( startFailed ) {
			print
				.line()
				.boldLine( "Why a server will not start, usually:" )
				.yellowLine( "  the file is missing from your project root" )
				.yellowLine( "  another server still holds the port" )
				.yellowLine( "  the engine could not be downloaded" )
				.line()
				.boldLine( "Try it by hand to see the real reason:" )
				.yellowLine( "  box server start serverConfigFile=#arguments.engine.configFile#" )
				.line()
				.toConsole();
			failSweep(
				"#arguments.engineName# would not start."
				& ( len( startError ) ? " " & startError : "" ),
				arguments.passed
			);
		}
	}

	/**
	 * waitForPortToFree
	 *
	 * Waits until nothing answers on the test port, so the next engine is not started while the
	 * last one is still letting go of it. Gives up after a short wait and lets the start attempt
	 * produce the real error.
	 *
	 * @engineName The engine about to start, for the message.
	 */
	private function waitForPortToFree( required string engineName ){
		var probeUrl = variables.config.probeUrl();
		for ( var attempt = 1; attempt <= 12; attempt++ ) {
			var answered = false;
			try {
				cfhttp(
					url          = probeUrl,
					method       = "GET",
					timeout      = 5,
					throwonerror = false,
					redirect     = false,
					result       = "local.probe"
				);
				answered = ( val( local.probe.statuscode ?: "0" ) > 0 );
			} catch ( any e ) {
				answered = false;
			}
			if ( !answered ) {
				return;
			}
			if ( attempt == 1 ) {
				print.yellowLine( "Waiting for the previous server to release the port..." ).toConsole();
			}
			sleep( 5000 );
		}
		print
			.yellowLine( "Something still answers on the port. Starting #arguments.engineName# anyway." )
			.toConsole();
	}

	/**
	 * warmUp
	 *
	 * Waits until the site answers, so the suite never runs against a server that is still
	 * starting up. A half-started app produces failures that look real but are not. Stops the
	 * run when the wait runs out.
	 *
	 * @engine     The engine entry from build.json.
	 * @engineName The name to show.
	 * @passed     What already passed, for the failure summary.
	 */
	private function warmUp( required struct engine, required string engineName, required array passed ){
		var attempts = variables.s.warmup.attempts;
		var delay    = variables.s.warmup.delaySeconds;
		var probeUrl = variables.config.probeUrl();

		print.blueLine( "Waiting for #arguments.engineName# (up to #attempts * delay# seconds)..." ).toConsole();
		var lastStatus = 0;
		for ( var attempt = 1; attempt <= attempts; attempt++ ) {
			var httpResult = "";
			try {
				cfhttp(
					url          = probeUrl,
					method       = "GET",
					timeout      = 60,
					throwonerror = false,
					redirect     = false,
					result       = "local.httpResult"
				);
				lastStatus = val( httpResult.statuscode ?: "0" );
			} catch ( any e ) {
				lastStatus = 0;
			}
			// Anything in the 200s or 300s means the site answered.
			if ( lastStatus >= 200 && lastStatus < 400 ) {
				print.greenLine( "#arguments.engineName# is up (status #lastStatus#)." ).toConsole();
				return;
			}
			sleep( delay * 1000 );
		}

		stopEngine( arguments.engine.configFile );
		failSweep(
			"#arguments.engineName# never answered (last status: #lastStatus#). "
			& "A repeating 500 usually means the app will not start on this engine. Start it by hand and read the log.",
			arguments.passed
		);
	}

	/**
	 * stopAllEngines
	 *
	 * Stops every listed engine, ignoring failures. At most one is running, and stopping one
	 * that is not running only prints a complaint.
	 */
	private function stopAllEngines(){
		print.blueLine( "Stopping any running server..." ).toConsole();
		for ( var engine in variables.s.engines ) {
			stopEngine( engine.configFile );
		}
	}

	/**
	 * stopEngine
	 *
	 * Stops one server quietly. A failure here never matters: either it was not running, or
	 * the next start will complain about the port anyway.
	 *
	 * @configFile The server json file for the engine to stop.
	 */
	private function stopEngine( required string configFile ){
		try {
			command( "server stop" ).params( serverConfigFile = arguments.configFile ).run();
		} catch ( any e ) {
			// Not running, nothing to do.
		}
	}

	/**
	 * failSweep
	 *
	 * Stops the run, saying what failed and what had already passed, so a long run that dies
	 * near the end still tells you which engines were fine.
	 *
	 * @message What failed.
	 * @passed  The engines that already passed.
	 */
	private function failSweep( required string message, required array passed ){
		var summary = arguments.passed.len()
			? "Already passed: #arguments.passed.toList( ', ' )#."
			: "Nothing had passed yet.";
		return error( arguments.message & " " & summary );
	}

	/**
	 * fail
	 *
	 * Stops the task, printing guidance that spans several lines.
	 *
	 * CommandBox's error() removes line breaks from its message, so anything longer than a
	 * sentence arrives as one run-together block. The guidance is printed first, where it keeps
	 * its shape, and error() is left with the single line that says what went wrong.
	 *
	 * @summary One line saying what went wrong.
	 * @detail  Lines of guidance to print first.
	 * @heading A short label for the guidance.
	 */
	private function fail( required string summary, array detail = [], string heading = "What to do" ){
		if ( arrayLen( arguments.detail ) ) {
			print.line().boldLine( arguments.heading & ":" ).toConsole();
			for ( var line in arguments.detail ) {
				print.yellowLine( "  " & line ).toConsole();
			}
			print.line().toConsole();
		}
		return error( arguments.summary );
	}
}
