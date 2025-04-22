/**
 * Copyright Since 2005 ColdBox Framework by Luis Majano and Ortus Solutions, Corp
 * www.ortussolutions.com
 * ---
 */
component {

	// Module Properties
	this.title 				= "sitemap-spider";
	this.author 			= "Angry Sam Productions";
	this.webURL 			= "https://www.angrysam.com";
	this.description 		= "@MODULE_DESCRIPTION@";
	this.version 			= "@build.version@+@build.number@";

	// Model Namespace
	this.modelNamespace		= "sitemap-spider";

	// CF Mapping
	this.cfmapping			= "sitemap-spider";

	// Dependencies
	this.dependencies 		= [ "cbjavaloader" ];

	/**
	 * Configure Module
	 */
	function configure(){
        // Module Settings
		settings = { libPath : modulePath & "/lib" };
	}

	/**
	 * Fired when the module is registered and activated.
	 */
	function onLoad(){
        //load jsoup
        wireBox.getInstance( "loader@cbjavaloader" ).appendPaths( settings.libPath );
	}

	/**
	 * Fired when the module is unregistered and unloaded
	 */
	function onUnload(){

	}

}
