interface {

    /**
     * Fetches a URL
     * @url The URL to fetch
     *
     * @returns (null or struct)
     */
    any function fetchUrl( required string url );

    /**
     * Fetches the raw text body of a URL, regardless of content type.
     * Used for robots.txt, which is served as text/plain and so is not returned
     * by fetchUrl (which only includes a body for HTML). Throws on a non-200
     * response so the caller can treat a missing robots.txt as "allow all".
     * @url The URL to fetch
     *
     * @returns string (the response body)
     */
    string function getText( required string url );

}