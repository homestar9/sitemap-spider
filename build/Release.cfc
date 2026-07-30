/**
 * Releases the project: check, build, publish, tag, and create a GitHub Release.
 *
 * Run it with: box run-script release
 *
 * The order matters. Everything that could stop a release happens before anything permanent:
 * the checks run before the forced checkout that would throw away uncommitted work, and before
 * ForgeBox receives anything. Once a version is published it cannot be taken back, so every
 * failure after that point prints the exact commands to finish by hand.
 *
 * Targets you can run on their own:
 *   run       Everything, in order. This is what box run-script release calls.
 *   preflight Just the checks.
 *   github    Just the tag and GitHub Release, for finishing a release that stopped halfway.
 *
 * Settings come from build/build.json. You should not need to edit this file.
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
	 * The whole release, in order.
	 *
	 * @version   The version to release. Defaults to the box.json version.
	 * @dryRun    Do everything except publish, tag, and push. Prints what it would have run.
	 *            Use this for your first release, or to test a change to the build.
	 * @skipTests Skip the test suite. For a hotfix you have already tested.
	 */
	function run( string version = "", boolean dryRun = false, boolean skipTests = false ){
		var releaseVersion = len( trim( arguments.version ) ) ? trim( arguments.version ) : variables.config.version();
		var tagName        = variables.s.tagPrefix & releaseVersion;

		if ( arguments.dryRun ) {
			print
				.line()
				.boldYellowLine( "DRY RUN: nothing will be published, tagged, or pushed." )
				.line()
				.toConsole();
		}

		// 1. Checks. These run first so nothing permanent has happened if one fails.
		preflight( version = releaseVersion, dryRun = arguments.dryRun );

		// 2. Line up with the remote, so only what is pushed gets released. This is skipped in
		//    a dry run because the forced checkout throws away uncommitted work.
		if ( variables.s.gitSync && !arguments.dryRun ) {
			syncWithRemote();
		} else if ( variables.s.gitSync ) {
			print.yellowLine( "Dry run: skipping git checkout and pull." ).toConsole();
		}

		// 3. Build. The suite runs here and stops the release if anything fails.
		runBuild( releaseVersion, arguments.skipTests );

		// 4. Publish to ForgeBox, from the built folder rather than the project root.
		if ( variables.s.publish.forgebox ) {
			publishToForgebox( releaseVersion, arguments.dryRun );
		} else {
			print.line().yellowLine( "Skipping ForgeBox (publish.forgebox is false in build.json)." ).toConsole();
		}

		// 5. Tag and create the GitHub Release.
		if ( variables.s.publish.github ) {
			github( version = releaseVersion, dryRun = arguments.dryRun );
		} else {
			print.yellowLine( "Skipping GitHub (publish.github is false in build.json)." ).toConsole();
		}

		print.line().toConsole();
		if ( arguments.dryRun ) {
			print
				.boldGreenLine( "Dry run finished. Nothing was published." )
				.line( "The package was built and checked. Run box run-script release when you are ready." )
				.toConsole();
		} else {
			print.boldGreenLine( "Released #tagName#." ).toConsole();
		}
	}

	/**
	 * preflight
	 *
	 * Everything that must be true before a release starts. Each check stops the run with a
	 * plain explanation of how to fix it.
	 *
	 * @version The version being released.
	 * @dryRun  Soften the checks that only matter for a real release.
	 */
	function preflight( string version = "", boolean dryRun = false ){
		var releaseVersion = len( trim( arguments.version ) ) ? trim( arguments.version ) : variables.config.version();

		print.boldBlueLine( "=== Checking ===" ).toConsole();

		// 1. git must be available and this must be a repository.
		var status = variables.config.execNative( "git", [ "status", "--porcelain" ] );
		if ( status.exitCode == 127 ) {
			return error( "Could not find git. Install it, or open a new terminal if you installed it recently." );
		}
		if ( status.exitCode != 0 ) {
			return error( "git could not read this folder (#status.output#). Is it a git repository?" );
		}

		// 2. Nothing uncommitted. This has to pass before the forced checkout later on, which
		//    would throw those changes away. A dry run never checks out anything, so there it
		//    is only worth a mention: rehearsing a release while still working is the point.
		if ( variables.s.requireCleanTree && len( trim( status.output ) ) ) {
			if ( arguments.dryRun ) {
				print
					.yellowLine( "  note  you have uncommitted changes; a real release would stop here" )
					.toConsole();
			} else {
				return fail(
					"You have uncommitted changes. Commit or stash them, then run this again.",
					listToArray( status.output, chr( 10 ) ),
					"Uncommitted"
				);
			}
		}

		// 3. Release only from the branch named in build.json.
		var branch = variables.config.execNative( "git", [ "rev-parse", "--abbrev-ref", "HEAD" ] );
		if ( trim( branch.output ) != variables.s.branch ) {
			return error(
				"Releases come from the #variables.s.branch# branch, but you are on #trim( branch.output )#. "
				& "Switch branch, or change ""branch"" in build/build.json."
			);
		}

		// 4. This version must not already be released. A missing tag exits non-zero, which is
		//    the answer we want here.
		var tagName  = variables.s.tagPrefix & releaseVersion;
		var tagCheck = variables.config.execNative( "git", [ "rev-parse", "-q", "--verify", "refs/tags/" & tagName ] );
		if ( tagCheck.exitCode == 0 ) {
			return error(
				"Tag #tagName# already exists, so #releaseVersion# has already been released. "
				& "Raise the version first: box run-script bump:patch"
			);
		}

		// 5. The changelog must have a section for this version. This is what makes sure notes
		//    are written before a release, and those notes become the GitHub Release body.
		if ( variables.s.publish.github ) {
			extractChangelogSection( releaseVersion );
		}

		// 6. The GitHub tool must be installed and signed in. Checking now, rather than after
		//    publishing, keeps ForgeBox and GitHub from drifting apart.
		if ( variables.s.publish.github && !arguments.dryRun ) {
			var ghCheck = variables.config.execNative( "gh", [ "auth", "status" ] );
			if ( ghCheck.exitCode == 127 ) {
				return fail(
					"Could not find the GitHub CLI (gh).",
					[
						"Install it from https://cli.github.com, then run: gh auth login",
						"",
						"If you have just installed it, open a new terminal. A terminal keeps the",
						"PATH it started with, so a tool added afterwards looks missing until then."
					]
				);
			}
			if ( ghCheck.exitCode != 0 ) {
				return fail(
					"The GitHub CLI is not signed in, so stopping before anything is published.",
					[ "gh auth login", "", "What gh said: " & ghCheck.output ]
				);
			}
		}

		print
			.greenLine( "  ok  clean checkout on #variables.s.branch#" )
			.greenLine( "  ok  #releaseVersion# has not been released" )
			.greenLine( variables.s.publish.github ? "  ok  changelog entry found" : "  --  changelog not needed" )
			.greenLine( variables.s.publish.github && !arguments.dryRun ? "  ok  GitHub CLI ready" : "  --  GitHub CLI not needed" )
			.toConsole();
	}

	/**
	 * github
	 *
	 * Tags the release, pushes it, and creates the GitHub Release with the changelog notes and
	 * the built zip attached.
	 *
	 * Run on its own to finish a release that stopped after publishing.
	 *
	 * @version   The version being released.
	 * @notesOnly Print the release notes and stop. Nothing is tagged or pushed.
	 * @dryRun    Print what would run without doing it.
	 */
	function github( string version = "", boolean notesOnly = false, boolean dryRun = false ){
		var releaseVersion = len( trim( arguments.version ) ) ? trim( arguments.version ) : variables.config.version();
		var tagName        = variables.s.tagPrefix & releaseVersion;
		var slug           = variables.config.slug();

		var notes = extractChangelogSection( releaseVersion );
		if ( arguments.notesOnly ) {
			print.line().boldLine( "Release notes for #tagName#:" ).line( notes ).toConsole();
			return;
		}

		// The zip the build produced. It goes on the GitHub Release with its checksum, so every
		// release keeps a copy of exactly what was published.
		var zipPath = variables.config.repoPath( "#variables.s.artifactsDir#/#slug#/#releaseVersion#/#slug#-#releaseVersion#.zip" );
		var shaPath = zipPath & ".sha512";
		if ( !fileExists( zipPath ) ) {
			return error(
				"No built zip at #zipPath#. Build it first: box run-script build:package"
			);
		}

		// gh reads the notes from a file so the markdown arrives untouched.
		var notesFile = variables.config.repoPath( "#variables.s.stagingDir#/release-notes.md" );
		if ( !directoryExists( getDirectoryFromPath( notesFile ) ) ) {
			directoryCreate( getDirectoryFromPath( notesFile ), true, true );
		}
		fileWrite( notesFile, notes );

		var ghArgs = [ "release", "create", tagName, "--title", tagName, "--notes-file", notesFile ];
		if ( isPrerelease( releaseVersion ) ) {
			ghArgs.append( "--prerelease" );
		}
		ghArgs.append( zipPath );
		if ( fileExists( shaPath ) ) {
			ghArgs.append( shaPath );
		}

		if ( arguments.dryRun ) {
			print
				.line()
				.boldYellowLine( "Dry run, would now run:" )
				.line( "  git tag #tagName#" )
				.line( "  git push origin #variables.s.branch#" )
				.line( "  git push origin #tagName#" )
				.line( "  gh " & arrayToList( ghArgs, " " ) )
				.line()
				.boldLine( "Release notes it would use:" )
				.line( notes )
				.toConsole();
			return;
		}

		// From here on, ForgeBox may already hold this version, so every failure explains how
		// to finish by hand rather than suggesting another full run.
		print.line().boldBlueLine( "=== Tagging and releasing on GitHub ===" ).toConsole();

		var result = variables.config.execNative( "git", [ "tag", tagName ] );
		if ( result.exitCode != 0 ) {
			return error( "Could not create tag #tagName#: #result.output#" );
		}

		result = variables.config.execNative( "git", [ "push", "origin", variables.s.branch ] );
		if ( result.exitCode != 0 ) {
			return failWithManualSteps( "The push failed (#result.output#).", tagName, ghArgs );
		}

		result = variables.config.execNative( "git", [ "push", "origin", tagName ] );
		if ( result.exitCode != 0 ) {
			return failWithManualSteps( "Pushing the tag failed (#result.output#).", tagName, ghArgs );
		}

		result = variables.config.execNative( "gh", ghArgs );
		if ( result.exitCode != 0 ) {
			return fail(
				"Creating the GitHub Release failed (#result.output#). The tag is already pushed.",
				[ "gh " & arrayToList( ghArgs, " " ) ],
				"Run this to finish"
			);
		}

		print.greenLine( "Tagged #tagName# and created the GitHub Release." ).toConsole();
	}

	/********************************************* PRIVATE HELPERS *********************************************/

	/**
	 * runBuild
	 *
	 * Runs Build.cfc and stops the release if the build fails.
	 *
	 * It starts Build.cfc as its own task rather than creating it directly. CommandBox hands a
	 * task the helpers it needs, such as command() and print, and a component created the
	 * ordinary way does not get them.
	 *
	 * @version   The version being built.
	 * @skipTests Skip the test suite.
	 */
	private function runBuild( required string version, boolean skipTests = false ){
		print.line().boldBlueLine( "=== Building ===" ).toConsole();

		var buildFailed = false;
		try {
			command( "task run" )
				.params(
					taskFile     = variables.config.buildPath( "Build.cfc" ),
					target       = "run",
					":version"   = arguments.version,
					":skipTests" = arguments.skipTests
				)
				.run();
			buildFailed = ( shell.getExitCode() != 0 );
		} catch ( any e ) {
			buildFailed = true;
			print.redLine( e.message ).toConsole();
		}

		if ( buildFailed ) {
			return error( "Stopping: the build failed, so nothing was published." );
		}
	}

	/**
	 * syncWithRemote
	 *
	 * Moves to the release branch and pulls, so the release matches what the remote holds. The
	 * forced checkout is safe because preflight has already proved nothing is uncommitted.
	 */
	private function syncWithRemote(){
		print.line().boldBlueLine( "=== Lining up with the remote ===" ).toConsole();

		var result = variables.config.execNative( "git", [ "checkout", "-f", variables.s.branch ] );
		if ( result.exitCode != 0 ) {
			return error( "Could not switch to #variables.s.branch#: #result.output#" );
		}

		result = variables.config.execNative( "git", [ "pull", "origin", variables.s.branch ] );
		if ( result.exitCode != 0 ) {
			var guidance = [ result.output ];
			if ( result.output contains "publickey" ) {
				guidance.append( "" );
				guidance.append( "git cannot sign in to your remote. Either add your SSH key at" );
				guidance.append( "https://github.com/settings/ssh/new, or switch the remote to HTTPS:" );
				guidance.append( "" );
				guidance.append( "  git remote set-url origin https://github.com/<you>/<repo>.git" );
				guidance.append( "  gh auth setup-git" );
			}
			return fail( "git pull failed.", guidance, "What git said" );
		}
		print.greenLine( "Up to date with origin/#variables.s.branch#." ).toConsole();
	}

	/**
	 * publishToForgebox
	 *
	 * Publishes from the built folder rather than the project root.
	 *
	 * This matters. Publishing from the project root packages using .gitignore, and one broad
	 * ignore rule can quietly drop source folders from what people install. Publishing the
	 * folder the build produced sends exactly what the build checked.
	 *
	 * @version The version being published.
	 * @dryRun  Print what would run without doing it.
	 */
	private function publishToForgebox( required string version, boolean dryRun = false ){
		var slug       = variables.config.slug();
		var publishDir = variables.config.repoPath( "#variables.s.stagingDir#/#slug#" );

		if ( arguments.dryRun ) {
			print
				.line()
				.boldYellowLine( "Dry run, would now publish to ForgeBox:" )
				.line( "  cd #publishDir#" )
				.line( "  publish" )
				.toConsole();
			return;
		}

		if ( !directoryExists( publishDir ) ) {
			return error( "No built folder at #publishDir#. The build should have created it." );
		}

		print.line().boldBlueLine( "=== Publishing to ForgeBox ===" ).toConsole();

		// Remember where we were, so a failed publish cannot leave the shell inside the
		// staging folder.
		var originalDir = shell.pwd();
		try {
			command( "cd" ).params( publishDir ).run();
			command( "publish" ).run();
			if ( shell.getExitCode() != 0 ) {
				return error( "Publishing to ForgeBox failed. Check you are signed in: box forgebox whoami" );
			}
		} finally {
			command( "cd" ).params( originalDir ).run();
		}

		print.greenLine( "Published #slug# #arguments.version# to ForgeBox." ).toConsole();
	}

	/**
	 * failWithManualSteps
	 *
	 * Stops the release after the package may already be published, printing the exact commands
	 * that finish the job. Running the release again would refuse, because the version is out.
	 *
	 * @reason  What failed.
	 * @tagName The tag for this release.
	 * @ghArgs  The arguments for the gh release command.
	 */
	private function failWithManualSteps( required string reason, required string tagName, required array ghArgs ){
		return fail(
			arguments.reason & " The package may already be published, so finish by hand rather than running the release again.",
			[
				"git push origin " & variables.s.branch,
				"git push origin " & arguments.tagName,
				"gh " & arrayToList( arguments.ghArgs, " " )
			],
			"Run these to finish"
		);
	}

	/**
	 * fail
	 *
	 * Stops the task, printing guidance that spans several lines.
	 *
	 * CommandBox's error() removes line breaks from its message, so anything longer than a
	 * sentence arrives as one run-together block. The guidance is printed first, where it keeps
	 * its shape, and error() is left with the single line that says what went wrong. That is
	 * also why the guidance appears above the error rather than below it: error() ends the task.
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

	/**
	 * extractChangelogSection
	 *
	 * Pulls one version's notes out of the changelog: everything between its "## [version]"
	 * heading and the next "##" heading. Stops the run when the section is missing, which is
	 * what makes sure notes exist before a release.
	 *
	 * A note on hashes: in CFML a doubled ## in a string means one literal #, so the patterns
	 * below use #### to match a two-hash "## " markdown heading.
	 *
	 * @version The version whose notes to pull out.
	 */
	private string function extractChangelogSection( required string version ){
		var changelogPath = variables.config.repoPath( variables.s.changelog );
		if ( !fileExists( changelogPath ) ) {
			return error( "No #variables.s.changelog# in the project root. Create one before releasing." );
		}

		var lines     = listToArray( fileRead( changelogPath ), chr( 10 ), true );
		var collected = [];
		var inSection = false;
		for ( var rawLine in lines ) {
			var line = reReplace( rawLine, chr( 13 ) & "$", "" );
			// A heading looks like "## [1.0.0] - 2026-07-24". Matching the literal [version]
			// avoids escaping the dots, and the closing bracket keeps 1.0.0 from matching
			// 1.0.0-beta.1.
			var isHeading = reFind( "^####\s*\[", line );
			if ( !inSection && isHeading && line contains "[#arguments.version#]" ) {
				inSection = true;
				continue;
			}
			if ( inSection ) {
				// The next heading ends the section. The link lines at the bottom never start
				// with ##, but they only appear after the last section, so they end it too.
				if ( reFind( "^####\s", line ) || reFind( "^\[.+\]:\s*http", line ) ) {
					break;
				}
				collected.append( line );
			}
		}

		if ( !inSection ) {
			return error(
				"#variables.s.changelog# has no ""#### [#arguments.version#]"" section. "
				& "Move your notes out of [Unreleased] into a dated section by running: box run-script bump:patch"
			);
		}

		var notes = trim( arrayToList( collected, chr( 10 ) ) );
		if ( !len( notes ) ) {
			return error( "The ""#### [#arguments.version#]"" section in #variables.s.changelog# is empty. Write the notes first." );
		}
		return notes;
	}

	/**
	 * isPrerelease
	 *
	 * A version with a hyphen, such as 1.0.0-beta.4, is a pre-release, so the GitHub Release
	 * is marked as one.
	 *
	 * @version The version being released.
	 */
	private boolean function isPrerelease( required string version ){
		return find( "-", arguments.version ) > 0;
	}
}
