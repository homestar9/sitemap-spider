/**
 * Build process for the sitemap-spider ColdBox module.
 *
 * Produces a ForgeBox-shaped artifact under .artifacts/<projectName>/<version>/
 * containing only the runtime files consumers need (ModuleConfig.cfc,
 * helpers/, models/, lib/, box.json, readme.md, changelog.md, LICENSE).
 *
 * Invoked by box.json's build:module script:
 *   task run taskFile=build/Build.cfc :projectName=sitemap-spider :version=1.0.0
 *
 * The version comes from box.json (the single source of truth) and is stamped
 * into ModuleConfig.cfc's this.version placeholder during the copy.
 */
component {

	/**
	 * Constructor — wires paths, excludes, and resets working directories.
	 */
	function init(){
		variables.cwd          = getCWD().reReplace( "\.$", "" );
		variables.artifactsDir = variables.cwd & "/.artifacts";
		variables.buildDir     = variables.cwd & "/.tmp";

		// Source excludes — regex patterns matched against paths under cwd.
		// `^\..*` covers every dotfile/dir: .artifacts, .tmp, .engine, .github,
		// .vscode, .gitignore, .cfformat.json, .cflintrc, .markdownlint.json,
		// .cfconfig.json, .env, etc.
		variables.excludes = [
			"build",
			"test-harness",
			"server-.*\.json",
			"test-results-.*\.txt",
			"(CLAUDE|AGENTS)\.md",
			"^\..*"
		];

		// Cleanup + init build directories
		[ variables.buildDir, variables.artifactsDir ].each( function( item ){
			if ( directoryExists( item ) ) {
				directoryDelete( item, true );
			}
			directoryCreate( item, true, true );
		} );

		return this;
	}

	/**
	 * Run the full build: copy source → token-replace → zip → checksums.
	 *
	 * @projectName The project name (used for the artifact filename and project mapping)
	 * @version     The version being built (defaults to 1.0.0 if not provided)
	 */
	function run(
		required projectName,
		version = "1.0.0"
	){
		// Project mapping so the module resolves under its slug during the build
		fileSystemUtil.createMapping( arguments.projectName, variables.cwd );

		buildSource( argumentCollection = arguments );
		buildChecksums();

		print
			.line()
			.boldMagentaLine( "Build Process is done! Enjoy your build!" )
			.toConsole();
	}

	/**
	 * Copy source into a clean working dir, swap the version token, and zip it
	 * into .artifacts/<projectName>/<version>/<projectName>-<version>.zip.
	 *
	 * @projectName The project name (used for the artifact filename and folder)
	 * @version     The version being built
	 */
	function buildSource(
		required projectName,
		version = "1.0.0"
	){
		print
			.line()
			.boldMagentaLine( "Building #arguments.projectName# v#arguments.version# from #variables.cwd#." )
			.toConsole();

		ensureExportDir( argumentCollection = arguments );

		variables.projectBuildDir = variables.buildDir & "/#arguments.projectName#";
		directoryCreate( variables.projectBuildDir, true, true );

		print.blueLine( "Copying source to build folder..." ).toConsole();
		copy( variables.cwd, variables.projectBuildDir );

		// Token replacement — rewrites ModuleConfig.cfc's this.version placeholder,
		// "@build.version@+@build.number@", in the copied source. First swap
		// @build.version@ for the real version from box.json (the single source of
		// truth), then drop the trailing "+@build.number@" so the stamped version
		// is exactly the box.json version (clean semver, no build-metadata suffix).
		print.greenLine( "Updating version identifier to #arguments.version#" ).toConsole();
		command( "tokenReplace" )
			.params(
				path        = "#variables.projectBuildDir#/**",
				token       = "@build.version@",
				replacement = arguments.version
			)
			.run();

		command( "tokenReplace" )
			.params(
				path        = "#variables.projectBuildDir#/**",
				token       = "+@build.number@",
				replacement = ""
			)
			.run();

		var destination = "#variables.exportsDir#/#arguments.projectName#-#arguments.version#.zip";
		print.greenLine( "Zipping code to #destination#" ).toConsole();
		cfzip(
			action    = "zip",
			file      = "#destination#",
			source    = "#variables.projectBuildDir#",
			overwrite = true,
			recurse   = true
		);

		// Copy box.json next to the zip for convenience (ForgeBox publish convention)
		fileCopy(
			"#variables.projectBuildDir#/box.json",
			variables.exportsDir
		);
	}

	/********************************************* PRIVATE HELPERS *********************************************/

	/**
	 * Write SHA-512 and MD5 checksum files next to every zip in the exports dir.
	 */
	private function buildChecksums(){
		print.greenLine( "Building checksums" ).toConsole();
		command( "checksum" )
			.params(
				path      = "#variables.exportsDir#/*.zip",
				algorithm = "SHA-512",
				extension = "sha512",
				write     = true
			)
			.run();
		command( "checksum" )
			.params(
				path      = "#variables.exportsDir#/*.zip",
				algorithm = "md5",
				extension = "md5",
				write     = true
			)
			.run();
	}

	/**
	 * Exclude-aware directory copy. Walks the top level of src, copying files
	 * and recursing into directories that don't match any pattern in variables.excludes.
	 *
	 * Hand-rolled instead of using directoryCopy with a filter because the
	 * combination has cross-engine quirks on Adobe CF and Lucee.
	 *
	 * @src     Source directory
	 * @target  Destination directory
	 * @recurse Reserved — directoryCopy below always recurses
	 */
	private function copy( src, target, recurse = true ){
		directoryList(
			arguments.src,
			false,
			"path",
			function( path ){
				var isExcluded = false;
				variables.excludes.each( function( item ){
					if ( path.replaceNoCase( variables.cwd, "", "all" ).reFindNoCase( item ) ) {
						isExcluded = true;
					}
				} );
				return !isExcluded;
			}
		).each( function( item ){
			if ( fileExists( item ) ) {
				print.blueLine( "Copying #item#" ).toConsole();
				fileCopy( item, target );
			} else {
				print.greenLine( "Copying directory #item#" ).toConsole();
				directoryCopy(
					item,
					target & "/" & item.replace( src, "" ),
					true
				);
			}
		} );
	}

	/**
	 * Idempotently create .artifacts/<projectName>/<version>/ and pin its path.
	 *
	 * @projectName The project name
	 * @version     The version being built
	 */
	private function ensureExportDir(
		required projectName,
		version = "1.0.0"
	){
		if ( structKeyExists( variables, "exportsDir" ) && directoryExists( variables.exportsDir ) ){
			return;
		}
		variables.exportsDir = variables.artifactsDir & "/#arguments.projectName#/#arguments.version#";
		directoryCreate( variables.exportsDir, true, true );
	}

}
