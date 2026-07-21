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
	this.description 		= "A ColdBox Module to crawl websites and generate sitemaps.";
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
		variables.settings = {
            libPath : modulePath & "/lib",
            browserDsl : "Jsoup@sitemap-spider",
            maxDepth : 10,
            maxPages : 1000,
            notAllowedPattern : "\.(png|webp|svg|gif|js|css|jpg|jpeg)$|javascript:|mailto:|tel:",
            priority : 1.0,
            priorityDecrement : 0.1, // each depth reduces priority by this much
            requestTimeout : 10000, // ms
            htmlContentTypePattern : "^(text/html|application/xhtml\+xml)(;.*)?$", // check for links + canonical URLs
            // Unanchored so it matches a canonical entry inside a multi-relation Link
            // header; the optional quotes accept rel=canonical and rel="canonical".
            canonicalHeaderPattern : '<([^>]+)>\s*;\s*rel\s*=\s*["'']?canonical["'']?'
        };
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
