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
     * Gets the last modified date from a fetch result as a real date object.
     * @fetchResult The fetch result containing headers and body.
     * @parsedPage The jSoup document for the page (optional). When present, its
     *   meta tags are read as a fallback when the HTTP header is missing.
     *
     * Returns a date object, or "" when no usable date is found. This function
     * is the single owner of last-modified *parsing*; the SitemapGenerator owns
     * *formatting*, so it receives a plain date-or-empty value and never has to
     * guess the format.
     *
     * Sources are tried in order:
     *   1. The HTTP "Last-Modified" response header (RFC 1123, e.g.
     *      "Wed, 21 Oct 2026 07:28:00 GMT").
     *   2. A <meta name="last-modified" content="..."> tag.
     *   3. A <meta property="article:modified_time" content="..."> Open Graph
     *      tag (ISO 8601).
     */
    any function getLastModified( required any fetchResult, any parsedPage ) {
        if ( fetchResult.headers.keyExists( "Last-Modified" ) ) {
            var headerDate = parseLastModifiedString( fetchResult.headers[ "Last-Modified" ] );
            if ( isDate( headerDate ) ) {
                return headerDate;
            }
        }

        // Fall back to meta tags on the parsed page, in priority order.
        if ( arguments.keyExists( "parsedPage" ) && !isNull( arguments.parsedPage ) ) {
            for ( var selector in [ "meta[name=last-modified]", "meta[property=article:modified_time]" ] ) {
                var meta = arguments.parsedPage.select( selector );
                if ( meta.size() ) {
                    var metaDate = parseLastModifiedString( meta.first().attr( "content" ) );
                    if ( isDate( metaDate ) ) {
                        return metaDate;
                    }
                }
            }
        }

        return "";
    }

    /**
     * Parses a last-modified string into a date object, or returns "" when it
     * cannot be parsed.
     * @raw The raw date string (an HTTP header value or a meta-tag content value).
     *
     * HTTP dates use RFC 1123 (e.g. "Wed, 21 Oct 2026 07:28:00 GMT"), which
     * CFML's isDate()/parseDateTime() do not reliably accept across Lucee,
     * Adobe, and BoxLang. Java's DateTimeFormatter.RFC_1123_DATE_TIME parses it
     * the same way on every engine, so it is tried first. Meta-tag values are
     * usually ISO 8601 (e.g. "2026-07-15T10:00:00+00:00"); those go through the
     * native parseDateTime() when isDate() accepts them, else Java's
     * OffsetDateTime as a last resort.
     *
     * Each Java parse is wrapped in try/catch so an unparseable value returns ""
     * instead of throwing.
     */
    private any function parseLastModifiedString( required string raw ) {
        var value = trim( arguments.raw );
        if ( !len( value ) ) {
            return "";
        }

        // 1. RFC 1123 HTTP-date (the "... GMT" header format).
        try {
            var rfc1123 = createObject( "java", "java.time.format.DateTimeFormatter" ).RFC_1123_DATE_TIME;
            var zdt = createObject( "java", "java.time.ZonedDateTime" ).parse( javaCast( "string", value ), rfc1123 );
            return createObject( "java", "java.util.Date" ).init( javaCast( "long", zdt.toInstant().toEpochMilli() ) );
        } catch ( any e ) {
            // Not an RFC 1123 date; fall through to the ISO handling below.
        }

        // 2. ISO 8601 / general date the engine already understands.
        if ( isDate( value ) ) {
            return parseDateTime( value );
        }

        // 3. ISO 8601 with an explicit offset, via Java as a last resort.
        try {
            var odt = createObject( "java", "java.time.OffsetDateTime" ).parse( javaCast( "string", value ) );
            return createObject( "java", "java.util.Date" ).init( javaCast( "long", odt.toInstant().toEpochMilli() ) );
        } catch ( any e ) {
            return "";
        }
    }

    string function getCanonicalUrl( required struct fetchResult, any parsedPage ) {
        // If parsedPage is provided, use it; otherwise, parse the HTML from fetchResult
        if ( arguments.keyExists( "parsedPage" ) ) {
            var canonical = arguments.parsedPage.select( "link[rel=canonical]" );
            if ( canonical.size() ) {
                return canonical.first().attr( "abs:href" );
            }
        }

        // Next try to get canonical from the Link header, which looks like:
        // <https://example.com/page.html>; rel="canonical"
        // A single Link header can carry several comma-separated relations, so the
        // canonicalHeaderPattern is unanchored: reFind scans the whole header and
        // finds the canonical entry wherever it sits among the others.
        if ( fetchResult.headers.keyExists( "Link" ) ) {
            var linkHeader = fetchResult.headers[ "Link" ];
            var match = reFind( settings.canonicalHeaderPattern, linkHeader, 1, true );
            // pos[2]/len[2] is capture group 1 (the URL inside <...>); pos[2] > 0
            // means the group matched.
            if ( match.pos.len() >= 2 && match.pos[ 2 ] > 0 ) {
                return mid( linkHeader, match.pos[ 2 ], match.len[ 2 ] );
            }
        }

        return "";
    }

    /**
     * Finds a meta-refresh redirect target on a parsed page and returns it as an
     * absolute, cleaned URL, or "" when the page has no such redirect.
     * @parsedPage The jSoup document for the page.
     * @baseUrl The page's own URL, used to resolve a relative target.
     *
     * A meta-refresh tag looks like:
     *   <meta http-equiv="refresh" content="3;url=redirect-new.cfm">
     * The number before the ";" is the delay in seconds; any delay counts as a
     * redirect here. A tag with no "url=" part (e.g. content="5") just reloads the
     * same page, so this returns "".
     *
     * The target is resolved against baseUrl with java.net.URL's two-argument
     * constructor. This manual resolution is required because jSoup's "abs:"
     * attribute prefix only resolves href/src attributes, not a URL parsed out of
     * the "content" attribute's string value. An already-absolute target is
     * returned unchanged (the two-arg constructor ignores the base then).
     */
    string function getMetaRefreshUrl( required any parsedPage, required string baseUrl ) {
        var meta = arguments.parsedPage.select( "meta[http-equiv=refresh]" );
        if ( !meta.size() ) {
            return "";
        }
        var content = meta.first().attr( "content" );
        // Capture the value after "url=", allowing spaces and optional quotes.
        var match = reFindNoCase( "url\s*=\s*[""']?([^""']+)", content, 1, true );
        if ( match.pos.len() < 2 || match.pos[ 2 ] == 0 ) {
            return "";
        }
        var rawTarget = trim( mid( content, match.pos[ 2 ], match.len[ 2 ] ) );
        if ( !len( rawTarget ) ) {
            return "";
        }
        try {
            var base = createObject( "java", "java.net.URL" ).init( javaCast( "string", arguments.baseUrl ) );
            var absolute = createObject( "java", "java.net.URL" ).init( base, javaCast( "string", rawTarget ) ).toString();
            return cleanUrl( absolute );
        } catch ( any e ) {
            logger.warn( "Could not resolve meta-refresh target '#rawTarget#' against '#arguments.baseUrl#': #e.message#" );
            return "";
        }
    }

    /**
     * Cleans and normalizes a URL string.
     * @url The URL to clean
     *
     * This is the single owner of URL-string normalization; the Crawler calls it
     * too (it replaced Crawler.normalizeUrl). It trims the ends, converts
     * backslashes to forward slashes, encodes interior spaces as %20, collapses
     * repeated slashes after the protocol, and strips the fragment.
     *
     * Encoding " " as "%20" after trimming never touches an existing %20, so an
     * already-encoded URL is preserved. The steps are idempotent, so calling
     * cleanUrl again on an already-cleaned URL returns the same string.
     */
    string function cleanUrl( required string url ) {
        var cleaned = trim( arguments.url );          // drop leading/trailing whitespace
        cleaned = cleaned.replace( "\", "/", "all" ); // backslash -> forward slash
        cleaned = reReplace( cleaned, "^(https?://[^/]+)//+", "\1/", "ALL" ); // collapse double slashes after protocol
        cleaned = cleaned.replace( " ", "%20", "all" ); // encode interior spaces
        // Remove the fragment, including the "#" itself (e.g., "page#anchor" -> "page")
        var fragmentIndex = cleaned.find( "##" );
        if ( fragmentIndex > 0 ) {
            cleaned = cleaned.left( fragmentIndex - 1 );
        }
        return cleaned;
    }

    /**
     * Checks if a URL is allowed based on settings
     * @url The URL to check
     *
     * This is the single owner of the "is this a crawlable URL for our host?"
     * rule; the Crawler delegates to it (it replaced Crawler.isUrlAllowed and
     * Crawler.isUrlHostMatch). A URL is allowed when it has a value, uses the
     * http or https protocol, its host matches variables.hostName, and it does
     * not match settings.notAllowedPattern (images, css/js, mailto:, tel:, etc.).
     */
    boolean function isUrlAllowed( required string url ) {
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