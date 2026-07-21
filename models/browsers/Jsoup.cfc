component 
    extends="BaseBrowser"
    implements="IBrowser" 
{

    property name="jSoup" inject="javaloader:org.jsoup.Jsoup";
    property name="logger" inject="logbox:logger:{this}";

    /**
     * Fetches a URL using jSoup
     * @url The URL to fetch
     */
    any function fetchUrl( required string url ) {
            
        var response = jSoup.connect( arguments.url )
            .userAgent( settings.userAgent )
            .timeout( settings.requestTimeout )
            .ignoreContentType( true ) // otherise only HTML is allowed
            .ignoreHttpErrors( true )
            .execute();

        // if status isn't 200, throw an exception
        if ( response.statusCode() != 200 ) {
            throw(
                message = "Failed to fetch #arguments.url# HTTP request returned status code #response.statusCode()#",
                type = "StatusCodeException"
            )
            return;
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

        // Check content type
        var contentType = response.contentType();
        var result = {
            url = arguments.url,
            headers = cfHeaders,
            contentType = contentType
        };

        // Only include body for HTML or XHTML content
        if ( isHtmlContentType( contentType ) ) {
            result.html = response.body(); // send back raw HTML content
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