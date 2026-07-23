component 
    extends="BaseBrowser"
    implements="IBrowser" 
{

    property name="jSoup" inject="javaloader:org.jsoup.Jsoup";
    property name="logger" inject="logbox:logger:{this}";

    /**
     * Fetches a URL using jSoup
     * @url The URL to fetch
     *
     * Follows HTTP 30x redirects itself (jsoup's own followRedirects is turned
     * off) so it can enforce the maxRedirects hop-limit and report the hop chain.
     * Each hop's { url, status } is collected; when more than one hop happened the
     * result carries a "redirectChain" array. A chain longer than maxRedirects
     * throws a TooManyRedirectsException; a terminal non-200 throws a
     * StatusCodeException, both recorded as bad URLs by the Crawler.
     *
     * Trade-off of following redirects here rather than in jsoup: jsoup's built-in
     * per-hop cookie handling is lost. Sitemap redirects rarely depend on cookies,
     * so this is acceptable for a crawler.
     */
    any function fetchUrl( required string url ) {

        var chain      = []; // one { url, status } per hop, first = requested URL
        var currentUrl = arguments.url;
        var hops       = 0;
        var response   = "";

        while ( true ) {
            response = jSoup.connect( currentUrl )
                .userAgent( settings.userAgent )
                .timeout( settings.requestTimeout )
                .ignoreContentType( true ) // otherise only HTML is allowed
                // Cap how many bytes jsoup reads. ignoreContentType( true ) means a
                // non-HTML body (a PDF or image that slips past notAllowedPattern)
                // would otherwise be pulled in full. maxBodySize bounds that. Trade-off:
                // an HTML page larger than the cap is truncated before parsing.
                .maxBodySize( settings.maxBodySize )
                .ignoreHttpErrors( true )
                .followRedirects( false ) // we follow them below to count + report hops
                .execute();

            var status = response.statusCode();
            chain.append( { "url" : currentUrl, "status" : status } );

            // A 30x with a Location header is a redirect to follow. A 3xx without
            // one (e.g. 304 Not Modified) is treated as a terminal response.
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

            // Resolve the Location against the current URL so a relative redirect
            // target (e.g. "/new") becomes an absolute URL.
            var location = response.header( "Location" );
            var base     = createObject( "java", "java.net.URL" ).init( javaCast( "string", currentUrl ) );
            currentUrl   = createObject( "java", "java.net.URL" ).init( base, javaCast( "string", location ) ).toString();
        }

        // if the terminal status isn't 200, throw an exception
        if ( response.statusCode() != 200 ) {
            throw(
                message = "Failed to fetch #arguments.url# HTTP request returned status code #response.statusCode()#",
                type = "StatusCodeException"
            );
        }

        // Convert headers to CF struct. Use multiHeaders() (Map<String,List<String>>)
        // instead of headers() (Map<String,String>), which keeps only one value per
        // name. Join the values for each name with ", " so a multi-relation Link
        // header survives. The values come back as a java List; concatenating via
        // size()/get() is portable across Lucee, Adobe, and BoxLang (Adobe cannot
        // resolve the static String.join via a createObject instance).
        var cfHeaders = {};
        var multiHeaders = response.multiHeaders();
        // Iterate entrySet rather than keySet+get: jsoup can carry a header whose
        // value list is null (e.g. the status line under an empty key), and on Adobe
        // a Java null return leaves the CF variable undefined. entry.getValue() with
        // an isNull guard avoids that.
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

        // Build the shared result shape. BaseBrowser.buildResult adds the body
        // under "html" only for HTML/XHTML content types.
        //
        // response.url() is the final URL we landed on after following any HTTP
        // 30x above; it equals the last chain entry's URL. It may differ from the
        // requested arguments.url. response.url() returns a java.net.URL, so
        // toString() makes it a CFML string.
        var result = buildResult(
            url = response.url().toString(),
            headers = cfHeaders,
            contentType = response.contentType(),
            body = response.body()
        );

        // Report the hop chain only when at least one redirect happened, so a
        // plain single-hop fetch keeps the same result shape as before.
        if ( chain.len() > 1 ) {
            result[ "redirectChain" ] = chain;
        }
        return result;
    }

    /**
     * Fetches the raw text body of a URL, regardless of content type. Used for
     * robots.txt (text/plain), which fetchUrl would drop. Throws a
     * StatusCodeException on a non-200 so the Crawler can fall back to allow-all.
     * @url The URL to fetch
     */
    string function getText( required string url ) {

        var response = jSoup.connect( arguments.url )
            .userAgent( settings.userAgent )
            .timeout( settings.requestTimeout )
            .ignoreContentType( true ) // robots.txt is text/plain, not HTML
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