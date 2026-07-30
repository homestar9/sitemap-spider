component 
    extends="BaseBrowser"
    implements="IBrowser" 
{

    property name="jSoup" inject="javaloader:org.jsoup.Jsoup";
    property name="logger" inject="logbox:logger:{this}";

    /**
     * fetchUrl
     *
     * Fetches a URL with jsoup. It follows redirects itself so it can enforce
     * maxRedirects and return each redirect step. This does not preserve jsoup's
     * automatic cookies between redirect requests.
     *
     * @url URL to fetch.
     */
    any function fetchUrl( required string url ) {

        var chain      = []; // One { url, status } entry per request.
        var currentUrl = arguments.url;
        var hops       = 0;
        var response   = "";

        while ( true ) {
            response = jSoup.connect( currentUrl )
                .userAgent( settings.userAgent )
                .timeout( settings.requestTimeout )
                .ignoreContentType( true ) // Allow text and non-HTML responses.
                // Limit all bodies. HTML larger than maxBodySize is truncated.
                .maxBodySize( settings.maxBodySize )
                .ignoreHttpErrors( true )
                .followRedirects( false ) // Follow redirects below so each hop is recorded.
                .execute();

            var status = response.statusCode();
            chain.append( { "url" : currentUrl, "status" : status } );

            // Follow only 30x responses that include Location.
            var isRedirect = status >= 300 && status < 400 && response.hasHeader( "Location" );
            if ( !isRedirect ) {
                break;
            }

            if ( hops >= settings.maxRedirects ) {
                throw(
                    message = "Too many redirects fetching #arguments.url# (exceeded #settings.maxRedirects# hops)",
                    type    = "TooManyRedirectsException"
                );
            }
            hops++;

            // Resolve a relative Location against the current URL.
            var location = response.header( "Location" );
            var base     = createObject( "java", "java.net.URL" ).init( javaCast( "string", currentUrl ) );
            currentUrl   = createObject( "java", "java.net.URL" ).init( base, javaCast( "string", location ) ).toString();
        }

        // Reject a final response that is not 200.
        if ( response.statusCode() != 200 ) {
            throw(
                message = "Failed to fetch #arguments.url# HTTP request returned status code #response.statusCode()#",
                type = "StatusCodeException"
            );
        }

        // Keep every value for repeated headers such as Link. Build the joined
        // string manually because Adobe cannot resolve Java String.join here.
        var cfHeaders = {};
        var multiHeaders = response.multiHeaders();
        // entrySet lets Adobe check a null header value without losing the variable.
        var iterator = multiHeaders.entrySet().iterator();
        while ( iterator.hasNext() ) {
            var entry = iterator.next();
            var key = entry.getKey();
            var values = entry.getValue();
            if ( isNull( key ) || isNull( values ) ) {
                continue;
            }
            var joined = "";
            for ( var i = 0; i < values.size(); i++ ) {
                joined &= ( i > 0 ? ", " : "" ) & values.get( i );
            }
            cfHeaders[ key ] = joined;
        }

        // Build the shared result with the final URL and optional HTML body.
        var result = buildResult(
            url = response.url().toString(),
            headers = cfHeaders,
            contentType = response.contentType(),
            body = response.body()
        );

        // Add redirectChain only when a redirect occurred.
        if ( chain.len() > 1 ) {
            result[ "redirectChain" ] = chain;
        }
        return result;
    }

    /**
     * getText
     *
     * Returns the raw response body for robots.txt. A non-200 response throws
     * StatusCodeException so the crawler can allow every URL.
     *
     * @url URL to fetch.
     */
    string function getText( required string url ) {

        var response = jSoup.connect( arguments.url )
            .userAgent( settings.userAgent )
            .timeout( settings.requestTimeout )
            .ignoreContentType( true ) // robots.txt is usually text/plain.
            .ignoreHttpErrors( true )
            .execute();

        if ( response.statusCode() != 200 ) {
            throw(
                message = "Failed to fetch #arguments.url# HTTP request returned status code #response.statusCode()#",
                type = "StatusCodeException"
            );
        }

        return response.body();
    }

}
