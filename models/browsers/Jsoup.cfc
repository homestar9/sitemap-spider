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

        // Convert headers to CF struct
        var cfHeaders = {};
        var headerMap = response.headers();
        for ( var key in headerMap.keySet() ) {
            cfHeaders[ key ] = headerMap.get( key );
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

}