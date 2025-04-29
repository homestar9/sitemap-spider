component accessors=true hint="Parses HTML content to extract links and metadata" {

    property name="hostName";
    property name="settings" inject="coldbox:moduleSettings:sitemap-spider";
    property name="logger" inject="logbox:logger:{this}";

    /**
     * Initializes the parser
     */
    function init( ) {
        variables.hostName = "";
        return this;
    }

    /**
     * Extracts links from a page
     * @page The jSoup page object
     * @baseUrl The base URL of the page for resolving relative URLs
     */
    array function getLinks( required any page ) {
        var links = [ ];
        arguments.page.select( "a[href]" ).each( function( link, index ) {
            var linkUrl = arguments.link.attr( "abs:href" );
            if ( 
                isUrlAllowed( linkUrl ) && 
                !links.find( linkUrl ) 
            ) {
                logger.info( "Valid link: #linkUrl#" );
                links.append( linkUrl );
            }
        } );
        return links;
    }

    /**
     * Gets the last modified date from a fetch result
     * @fetchResult The fetch result containing headers and body
     */
    string function getLastModified( required any fetchResult ) {
        if ( fetchResult.headers.keyExists( "Last-Modified" ) ) {
            return fetchResult.headers[ "Last-Modified" ];
        }
        // TODO: Add support for custom meta tag selectors
        return "";
    }

    string function getCanonicalUrl( required any fetchResult ) {
        var canonical = fetchResult.select("link[rel=canonical]");
        if ( canonical.size() ) {
            return canonical.first().attr( "abs:href" );
        }
        return "";
    }

    /**
     * Cleans a URL by removing unwanted characters
     * @url The URL to clean
     */
    private string function cleanUrl( required string url ) {
        var cleaned = arguments.url
            .replace( " ", "", "all" )
            .replace( "%20", "", "all" )
            .replace( "\", "/", "all" );
        // Remove fragments (e.g., #anchor)
        var fragmentIndex = cleaned.find( "##" );
        if ( fragmentIndex > 0 ) {
            cleaned = cleaned.left( fragmentIndex );
        }
        // Ensure trailing slash for consistency
        if ( !cleaned.endsWith( "/" ) && !cleaned.reFind( "\.[a-zA-Z0-9]+$" ) ) {
            cleaned &= "/";
        }
        return cleaned;
    }

    /**
     * Checks if a URL is allowed based on settings
     * @url The URL to check
     */
    private boolean function isUrlAllowed( required string url ) {
        if ( !len( arguments.url ) ) {
            return false;
        }
        try {
            var urlObj = createObject( "java", "java.net.URL" ).init( javaCast( "string", arguments.url ) );
            var protocol = urlObj.getProtocol( );
            var host = urlObj.getHost( );
            return ( protocol == "http" || protocol == "https" ) &&
                host == variables.hostName &&
                !reFindNoCase( settings.notAllowedPattern, arguments.url );
        } catch ( any e ) {
            logger.debug( "Invalid URL: #arguments.url# - #e.message#" );
            return false;
        }
    }

}