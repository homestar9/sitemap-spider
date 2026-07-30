component 
    extends="BaseBrowser"
    implements="IBrowser" 
{

    property name="jSoup" inject="javaloader:org.jsoup.Jsoup";
    // jsoup's HTTP method enum. cbjavaloader owns the jar's classes, so this must
    // be injected rather than built with createObject( "java", ... ).
    property name="jSoupMethod" inject="javaloader:org.jsoup.Connection$Method";
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
                    type    = "TooManyRedirectsException",
                    // status 0 because no final response was ever reached.
                    errorCode    = 0,
                    extendedInfo = serializeJSON( { "status" : 0, "url" : currentUrl, "chain" : chain } )
                );
            }
            hops++;

            // Resolve a relative Location against the current URL.
            var location = response.header( "Location" );
            var base     = createObject( "java", "java.net.URL" ).init( javaCast( "string", currentUrl ) );
            currentUrl   = createObject( "java", "java.net.URL" ).init( base, javaCast( "string", location ) ).toString();
        }

        // Reject a final response that is not 200. errorCode and extendedInfo carry
        // the status and redirect steps, which the message only holds as text.
        if ( response.statusCode() != 200 ) {
            throw(
                message = "Failed to fetch #arguments.url# HTTP request returned status code #response.statusCode()#",
                type = "StatusCodeException",
                errorCode    = response.statusCode(),
                extendedInfo = serializeJSON( {
                    "status" : response.statusCode(),
                    "url"    : currentUrl,
                    "chain"  : chain
                } )
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
     * checkUrl
     *
     * Requests only the status of a URL, for files the crawler never fetches as
     * pages such as images, stylesheets, and PDFs.
     *
     * A HEAD request avoids downloading the file. Plenty of servers reject HEAD,
     * so a 405 or 501 retries with a GET capped at one byte, which still reads the
     * status without pulling the body.
     *
     * This never throws. A connection failure returns ok=false with status 0 and
     * the reason in error, because the crawler checks many URLs in a row and needs
     * an answer for each one.
     *
     * @url URL to check.
     */
    struct function checkUrl( required string url ) {
        try {
            var response = requestStatus( arguments.url, "HEAD" );

            // Retry with GET when the server refuses HEAD.
            var status = response.statusCode();
            if ( status == 405 || status == 501 ) {
                response = requestStatus( arguments.url, "GET" );
                status   = response.statusCode();
            }

            return {
                "ok"            : status >= 200 && status < 400,
                "status"        : status,
                "url"           : response.url().toString(),
                "redirectChain" : [],
                "error"         : ""
            };
        } catch ( any e ) {
            logger.warn( "Could not check #arguments.url#: #e.message#" );
            return {
                "ok"            : false,
                "status"        : 0,
                "url"           : arguments.url,
                "redirectChain" : [],
                "error"         : e.message
            };
        }
    }

    /**
     * requestStatus
     *
     * Makes one request for checkUrl() and returns the jsoup response. Redirects
     * are followed here so a moved file is not reported as broken. maxBodySize is
     * 1 byte because only the status matters.
     *
     * @url URL to request.
     * @method HTTP method, either HEAD or GET.
     */
    private any function requestStatus( required string url, required string method ) {
        var httpMethod = jSoupMethod.valueOf( javaCast( "string", arguments.method ) );
        return jSoup.connect( arguments.url )
            .userAgent( settings.userAgent )
            .timeout( settings.requestTimeout )
            .ignoreContentType( true )
            .ignoreHttpErrors( true )
            .followRedirects( true )
            .maxBodySize( javaCast( "int", 1 ) )
            .method( httpMethod )
            .execute();
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
                type = "StatusCodeException",
                errorCode = response.statusCode()
            );
        }

        return response.body();
    }

}
