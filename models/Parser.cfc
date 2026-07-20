component accessors=true hint="Parses HTML content to extract links and metadata" {

    property name="hostName";
    property name="jSoup" inject="javaloader:org.jsoup.Jsoup";
    property name="settings" inject="coldbox:moduleSettings:sitemap-spider";
    property name="logger" inject="logbox:logger:{this}";

    /**
     * Initializes the parser
     */
    function init( ) {
        variables.hostName = "";
        return this;
    }


    any function parseHtml( required string html ) {
        return jSoup.parse( arguments.html );
    }

    /**
     * Extracts links from a page
     * @page The jSoup page object
     * @baseUrl The base URL of the page for resolving relative URLs
     */
    array function getLinks( required any page ) {
        var links = [ ];
        arguments.page.select( "a[href]" ).each( function( link, index ) {
            var linkUrl = cleanUrl( arguments.link.attr( "abs:href" ) );
            logger.info( "Found link: #linkUrl#" );
            if ( 
                isUrlAllowed( linkUrl ) && 
                !isNoFollow( arguments.link ) &&
                !links.find( linkUrl ) 
            ) {
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

    string function getCanonicalUrl( required struct fetchResult, any parsedPage ) {
        // If parsedPage is provided, use it; otherwise, parse the HTML from fetchResult
        if ( arguments.keyExists( "parsedPage" ) ) {
            var canonical = parsedPage.select("link[rel=canonical]");
            if ( canonical.size() ) {
                return canonical.first().attr( "abs:href" );
            }
        }

        // next try to get canonical from fetchResult.headers
        // header will look like: <https://example.com/page.html>; rel="canonical"
        if ( fetchResult.headers.keyExists( "Link" ) ) {
            var linkHeader = fetchResult.headers[ "Link" ];
            // Use regex to extract the URL from the Link header
            var matches = reMatch( '^<([^>]+)>\s*;\s*rel\s*=\s*["'']?canonical["'']?$', linkHeader );
            if ( matches.len() ) {
                // Extract URL from <...> in first match
                var urlMatch = reMatch( '^<([^>]+)>', matches[1] );
                if ( urlMatch.len() ) {
                    // strip the left and right brackets
                    return mid( urlMatch[ 1 ], 2, len( urlMatch[ 1 ] ) - 1 );
                }
            }
        }
        
        return "";
    }

    /**
     * Cleans a URL by removing unwanted characters
     * @url The URL to clean
     */
    private string function cleanUrl( required string url ) {
        var cleaned = arguments.url
            .replace( " ", "", "all" ) // remove spaces
            .replace( "%20", "", "all" ) // remove URL-encoded spaces
            .replace( "\", "/", "all" );  // ensure slash is used instead of backslash
        // Remove fragments (e.g., #anchor)
        var fragmentIndex = cleaned.find( "##" );
        if ( fragmentIndex > 0 ) {
            cleaned = cleaned.left( fragmentIndex );
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

            logger.info( "Checking URL: #arguments.url#, Protocol: #protocol#, Host: #host#" );

            return ( protocol == "http" || protocol == "https" ) &&
                host == variables.hostName &&
                !reFindNoCase( settings.notAllowedPattern, arguments.url );
        } catch ( any e ) {
            //logger.debug( "Invalid URL: #arguments.url# - #e.message#" );
            return false;
        }
    }

    /**
     * isNoFollow
     * Checks if a link has rel="nofollow"
     * @link The jSoup link element
     */
    private function isNoFollow( required any link ) {
        var relAttr = link.attr( "rel" );
        if ( len( relAttr ) ) {
            var relValues = listToArray( relAttr, " " );
            return arrayFindNoCase( relValues, "nofollow" ) > 0;
        }
        return false;
    }

}