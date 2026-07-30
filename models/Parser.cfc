component accessors=true hint="Parses HTML content to extract links and metadata" {

    property name="hostName";
    property name="jSoup" inject="javaloader:org.jsoup.Jsoup";
    property name="settings" inject="coldbox:moduleSettings:sitemap-spider";
    property name="logger" inject="logbox:logger:{this}";

    /**
     * init
     *
     * Sets the allowed host to an empty value.
     */
    function init( ) {
        variables.hostName = "";
        return this;
    }


    /**
     * parseHtml
     *
     * Parses HTML into a jsoup document.
     *
     * @html The raw HTML to parse.
     * @baseUri Page URL used to resolve relative links. A <base> tag overrides it.
     */
    any function parseHtml( required string html, string baseUri = "" ) {
        return jSoup.parse( arguments.html, arguments.baseUri );
    }

    /**
     * getLinks
     *
     * Returns unique crawlable links and on-host links marked nofollow.
     * Off-host links, blocked URL types, and duplicates are omitted.
     *
     * @page jsoup document with a base URI or <base> tag.
     * @return A struct with links and ignored arrays.
     */
    struct function getLinks( required any page ) {
        var links   = [ ];
        var ignored = [ ];
        arguments.page.select( "a[href]" ).each( function( link, index ) {
            var linkUrl = cleanUrl( arguments.link.attr( "abs:href" ) );
            logger.info( "Found link: #linkUrl#" );
            if ( !isUrlAllowed( linkUrl ) ) {
                return; // Skip off-host URLs and blocked URL types.
            }
            if ( isNoFollow( arguments.link ) ) {
                ignored.append( { "url": linkUrl, "reason": "nofollow" } );
                return;
            }
            if ( links.find( linkUrl ) ) {
                return; // Skip duplicates from this page.
            }
            links.append( linkUrl );
        } );
        return { "links": links, "ignored": ignored };
    }

    /**
     * getImages
     *
     * Returns up to 1,000 unique absolute image URLs. Images can use another host.
     *
     * @page jsoup document with a base URI or <base> tag.
     */
    array function getImages( required any page ) {
        var images = [];
        var seen   = {};
        arguments.page.select( "img[src]" ).each( function( img ) {
            // Check raw src because jsoup resolves src="" to the page URL.
            // data: values are inline images and cannot be crawled.
            var rawSrc = trim( arguments.img.attr( "src" ) );
            if ( !len( rawSrc ) || left( rawSrc, 5 ) == "data:" ) {
                return;
            }
            var src = trim( arguments.img.attr( "abs:src" ) );
            if ( !len( src ) ) {
                return; // The image URL could not be resolved.
            }
            if ( seen.keyExists( src ) || images.len() >= 1000 ) {
                return; // Skip duplicates and images past Google's limit.
            }
            seen[ src ] = true;
            images.append( src );
        } );
        return images;
    }

    /**
     * getAlternateLinks
     *
     * Returns up to 1,000 unique hreflang and href pairs. The href can use
     * another host and is not required to appear in the crawl.
     *
     * @page jsoup document with a base URI or <base> tag.
     */
    array function getAlternateLinks( required any page ) {
        var alternates = [ ];
        var seen       = { };
        arguments.page.select( "link[rel=alternate][hreflang]" ).each( function( link ) {
            var hreflang = trim( arguments.link.attr( "hreflang" ) );
            // Check raw href because jsoup resolves href="" to the page URL.
            var rawHref = trim( arguments.link.attr( "href" ) );
            if ( !len( hreflang ) || !len( rawHref ) ) {
                return;
            }
            var href = trim( arguments.link.attr( "abs:href" ) );
            if ( !len( href ) ) {
                return; // The alternate URL could not be resolved.
            }
            var pairKey = hreflang & "|" & href;
            if ( seen.keyExists( pairKey ) || alternates.len() >= 1000 ) {
                return; // Skip duplicate pairs and entries past the limit.
            }
            seen[ pairKey ] = true;
            alternates.append( { "hreflang": hreflang, "href": href } );
        } );
        return alternates;
    }

    /**
     * getVideos
     *
     * Returns up to 100 valid, unique videos from JSON-LD, Open Graph, and
     * <video> elements, in that order. Each result contains title, description,
     * thumbnailLoc, contentLoc, playerLoc, and duration.
     *
     * Google requires a title, description, thumbnail, and content or player
     * URL. Incomplete videos are omitted. Earlier sources win when URLs repeat.
     *
     * @page jsoup document with a base URI or <base> tag.
     */
    array function getVideos( required any page ) {
        var baseUri = arguments.page.baseUri();

        // Read page-level values used when a video has no value of its own.
        var pageTitle = metaContent( arguments.page, "meta[property=og:title]" );
        if ( !len( pageTitle ) ) {
            pageTitle = trim( arguments.page.title() );
        }
        var pageDescription = metaContent( arguments.page, "meta[property=og:description]" );
        if ( !len( pageDescription ) ) {
            pageDescription = metaContent( arguments.page, "meta[name=description]" );
        }
        var pageThumbnail = resolveAgainstBase( metaContent( arguments.page, "meta[property=og:image]" ), baseUri );

        // Collect every source before validating and removing duplicates.
        var candidates = [ ];

        // Read JSON-LD VideoObject entries first.
        for ( var videoObject in jsonLdVideoObjects( arguments.page ) ) {
            var jsonLdTitle = jsonLdString( videoObject, "name" );
            var jsonLdDescription = jsonLdString( videoObject, "description" );
            var jsonLdThumbnail = resolveAgainstBase( jsonLdUrl( videoObject, "thumbnailUrl" ), baseUri );
            candidates.append( {
                "title": len( jsonLdTitle ) ? jsonLdTitle : pageTitle,
                "description": len( jsonLdDescription ) ? jsonLdDescription : pageDescription,
                "thumbnailLoc": len( jsonLdThumbnail ) ? jsonLdThumbnail : pageThumbnail,
                "contentLoc": resolveAgainstBase( jsonLdUrl( videoObject, "contentUrl" ), baseUri ),
                "playerLoc": resolveAgainstBase( jsonLdUrl( videoObject, "embedUrl" ), baseUri ),
                "duration": iso8601Seconds( jsonLdString( videoObject, "duration" ) )
            } );
        }

        // Read one Open Graph player URL. Prefer its secure form.
        var ogUrl = metaContent( arguments.page, "meta[property=og:video:secure_url]" );
        if ( !len( ogUrl ) ) {
            ogUrl = metaContent( arguments.page, "meta[property=og:video:url]" );
        }
        if ( !len( ogUrl ) ) {
            ogUrl = metaContent( arguments.page, "meta[property=og:video]" );
        }
        ogUrl = resolveAgainstBase( ogUrl, baseUri );
        if ( len( ogUrl ) ) {
            candidates.append( {
                "title": pageTitle,
                "description": pageDescription,
                "thumbnailLoc": pageThumbnail,
                "contentLoc": "",
                "playerLoc": ogUrl,
                "duration": 0
            } );
        }

        // Read HTML <video> elements with page-level title and description.
        for ( var element in arguments.page.select( "video" ) ) {
            // Use the element's src or its first non-empty <source> child.
            var contentLoc = "";
            if ( len( trim( element.attr( "src" ) ) ) ) {
                contentLoc = trim( element.attr( "abs:src" ) );
            } else {
                var sources = element.select( "source[src]" );
                for ( var source in sources ) {
                    if ( len( trim( source.attr( "src" ) ) ) ) {
                        contentLoc = trim( source.attr( "abs:src" ) );
                        break;
                    }
                }
            }
            var thumbnail = len( trim( element.attr( "poster" ) ) )
                ? trim( element.attr( "abs:poster" ) )
                : pageThumbnail;
            candidates.append( {
                "title": pageTitle,
                "description": pageDescription,
                "thumbnailLoc": thumbnail,
                "contentLoc": contentLoc,
                "playerLoc": "",
                "duration": 0
            } );
        }

        // Remove incomplete and duplicate videos. Compare every content and player URL.
        var videos = [ ];
        var seen   = { };
        for ( var candidate in candidates ) {
            var candidateUrls = [ ];
            if ( len( candidate.contentLoc ) ) {
                candidateUrls.append( candidate.contentLoc );
            }
            if ( len( candidate.playerLoc ) ) {
                candidateUrls.append( candidate.playerLoc );
            }
            if (
                !candidateUrls.len()
                || !len( candidate.thumbnailLoc )
                || !len( candidate.title )
                || !len( candidate.description )
            ) {
                logger.debug( "Dropping incomplete video candidate on #baseUri#" );
                continue;
            }
            var isDuplicate = false;
            for ( var candidateUrl in candidateUrls ) {
                if ( seen.keyExists( candidateUrl ) ) {
                    isDuplicate = true;
                    break;
                }
            }
            if ( isDuplicate || videos.len() >= 100 ) {
                continue; // Skip duplicates and videos past the limit.
            }
            for ( var candidateUrl in candidateUrls ) {
                seen[ candidateUrl ] = true;
            }
            videos.append( candidate );
        }
        return videos;
    }

    /**
     * metaContent
     *
     * Returns the first matching content attribute, or an empty string.
     */
    private string function metaContent( required any page, required string selector ) {
        var found = arguments.page.select( arguments.selector );
        if ( !found.size() ) {
            return "";
        }
        return trim( found.first().attr( "content" ) );
    }

    /**
     * resolveAgainstBase
     *
     * Resolves a relative URL against baseUrl. jsoup cannot resolve URLs stored
     * in a meta tag's content attribute.
     */
    private string function resolveAgainstBase( required string raw, required string baseUrl ) {
        var target = trim( arguments.raw );
        if ( !len( target ) ) {
            return "";
        }
        try {
            if ( !len( arguments.baseUrl ) ) {
                return createObject( "java", "java.net.URL" ).init( javaCast( "string", target ) ).toString();
            }
            var base = createObject( "java", "java.net.URL" ).init( javaCast( "string", arguments.baseUrl ) );
            return createObject( "java", "java.net.URL" ).init( base, javaCast( "string", target ) ).toString();
        } catch ( any e ) {
            return "";
        }
    }

    /**
     * jsonLdVideoObjects
     *
     * Returns VideoObject structs from the page's JSON-LD scripts.
     * Invalid JSON is skipped so one script cannot fail the crawl. jsoup data()
     * must be used because text() does not return script contents.
     */
    private array function jsonLdVideoObjects( required any page ) {
        var found = [ ];
        for ( var block in arguments.page.select( "script[type=application/ld+json]" ) ) {
            var raw = trim( block.data() );
            if ( !len( raw ) || !isJSON( raw ) ) {
                continue;
            }
            try {
                collectVideoObjects( deserializeJSON( raw ), found, 0 );
            } catch ( any e ) {
                // Skip a value the current engine could not deserialize.
                logger.debug( "Skipping unreadable JSON-LD block: #e.message#" );
            }
        }
        return found;
    }

    /**
     * collectVideoObjects
     *
     * Recursively adds VideoObject structs from a JSON-LD value. Depth and
     * result limits prevent a large script from delaying the crawl.
     *
     * @node JSON-LD value to walk.
     * @found Array that receives each match.
     * @depth How far into the document this call is.
     */
    private void function collectVideoObjects( required any node, required array found, numeric depth = 0 ) {
        if ( arguments.depth > 10 || arguments.found.len() >= 100 ) {
            return;
        }
        if ( isArray( arguments.node ) ) {
            for ( var item in arguments.node ) {
                collectVideoObjects( item, arguments.found, arguments.depth + 1 );
            }
            return;
        }
        if ( !isStruct( arguments.node ) ) {
            return;
        }
        if ( isVideoObject( arguments.node ) ) {
            arguments.found.append( arguments.node );
        }
        for ( var key in arguments.node ) {
            collectVideoObjects( arguments.node[ key ], arguments.found, arguments.depth + 1 );
        }
    }

    /**
     * isVideoObject
     *
     * Returns whether a JSON-LD @type names VideoObject. @type can be a string,
     * an array, or a full schema.org URL.
     */
    private boolean function isVideoObject( required struct node ) {
        if ( !arguments.node.keyExists( "@type" ) ) {
            return false;
        }
        var rawType = arguments.node[ "@type" ];
        var types = isArray( rawType ) ? rawType : [ rawType ];
        for ( var type in types ) {
            if ( isSimpleValue( type ) && listLast( trim( type ), "/" ) == "VideoObject" ) {
                return true;
            }
        }
        return false;
    }

    /**
     * jsonLdString
     *
     * Returns a JSON-LD struct's value for a key as a trimmed string, or ""
     * when the key is missing or holds something that is not a simple value.
     */
    private string function jsonLdString( required struct node, required string key ) {
        if ( !arguments.node.keyExists( arguments.key ) ) {
            return "";
        }
        var value = arguments.node[ arguments.key ];
        return isSimpleValue( value ) ? trim( value ) : "";
    }

    /**
     * jsonLdUrl
     *
     * Returns the first URL stored as a string, array value, or nested object.
     */
    private string function jsonLdUrl( required struct node, required string key ) {
        if ( !arguments.node.keyExists( arguments.key ) ) {
            return "";
        }
        return firstUrlValue( arguments.node[ arguments.key ] );
    }

    /**
     * firstUrlValue
     *
     * Returns the first URL found in a JSON-LD value.
     */
    private string function firstUrlValue( required any value ) {
        if ( isSimpleValue( arguments.value ) ) {
            return trim( arguments.value );
        }
        if ( isArray( arguments.value ) ) {
            for ( var item in arguments.value ) {
                var itemUrl = firstUrlValue( item );
                if ( len( itemUrl ) ) {
                    return itemUrl;
                }
            }
            return "";
        }
        if ( isStruct( arguments.value ) ) {
            for ( var urlKey in [ "url", "contentUrl", "@id" ] ) {
                if ( arguments.value.keyExists( urlKey ) && isSimpleValue( arguments.value[ urlKey ] ) ) {
                    return trim( arguments.value[ urlKey ] );
                }
            }
        }
        return "";
    }

    /**
     * iso8601Seconds
     *
     * Converts an ISO-8601 duration or numeric value to whole seconds.
     * Returns 0 outside Google's 1–28,800 second range. Month and year values
     * also return 0 because they do not have a fixed number of seconds.
     */
    private numeric function iso8601Seconds( required string raw ) {
        var value = trim( arguments.raw );
        if ( !len( value ) ) {
            return 0;
        }
        var seconds = 0;
        if ( isNumeric( value ) ) {
            seconds = int( value );
        } else if ( left( value, 1 ) == "P" ) {
            var body = mid( value, 2, len( value ) - 1 );
            var timeStart = body.findNoCase( "T" );
            var datePart = timeStart ? ( timeStart > 1 ? left( body, timeStart - 1 ) : "" ) : body;
            var timePart = timeStart ? mid( body, timeStart + 1, len( body ) ) : "";
            // Months and years do not have a fixed number of seconds.
            if ( reFindNoCase( "[0-9][YM]", datePart ) ) {
                return 0;
            }
            for ( var part in reMatchNoCase( "[0-9]+(\.[0-9]+)?[DW]", datePart ) ) {
                var dayCount = val( part );
                seconds += right( part, 1 ) == "W" ? dayCount * 604800 : dayCount * 86400;
            }
            for ( var part in reMatchNoCase( "[0-9]+(\.[0-9]+)?[HMS]", timePart ) ) {
                var unitCount = val( part );
                switch ( uCase( right( part, 1 ) ) ) {
                    case "H":
                        seconds += unitCount * 3600;
                        break;
                    case "M":
                        seconds += unitCount * 60;
                        break;
                    default:
                        seconds += unitCount;
                }
            }
            seconds = int( seconds );
        }
        return ( seconds >= 1 && seconds <= 28800 ) ? seconds : 0;
    }

    /**
     * getLastModified
     *
     * Returns a parsed last-modified date, or an empty string. It checks the
     * Last-Modified header, last-modified meta tag, then article:modified_time.
     *
     * @fetchResult Fetch result containing response headers.
     * @parsedPage Optional jsoup document used for meta-tag fallbacks.
     */
    any function getLastModified( required any fetchResult, any parsedPage ) {
        if ( fetchResult.headers.keyExists( "Last-Modified" ) ) {
            var headerDate = parseLastModifiedString( fetchResult.headers[ "Last-Modified" ] );
            if ( isDate( headerDate ) ) {
                return headerDate;
            }
        }

        // Check page metadata when the response header has no usable date.
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
     * parseLastModifiedString
     *
     * Parses RFC-1123 or ISO-8601 text into a date. Java handles RFC-1123
     * consistently across Adobe, Lucee, and BoxLang. Invalid text returns "".
     *
     * @raw HTTP header or meta-tag date text.
     */
    private any function parseLastModifiedString( required string raw ) {
        var value = trim( arguments.raw );
        if ( !len( value ) ) {
            return "";
        }

        // Try the RFC-1123 HTTP header format.
        try {
            var rfc1123 = createObject( "java", "java.time.format.DateTimeFormatter" ).RFC_1123_DATE_TIME;
            var zdt = createObject( "java", "java.time.ZonedDateTime" ).parse( javaCast( "string", value ), rfc1123 );
            return createObject( "java", "java.util.Date" ).init( javaCast( "long", zdt.toInstant().toEpochMilli() ) );
        } catch ( any e ) {
            // Continue with ISO formats.
        }

        // Use the engine's date parser when possible.
        if ( isDate( value ) ) {
            return parseDateTime( value );
        }

        // Use Java for an ISO-8601 value with an explicit offset.
        try {
            var odt = createObject( "java", "java.time.OffsetDateTime" ).parse( javaCast( "string", value ) );
            return createObject( "java", "java.util.Date" ).init( javaCast( "long", odt.toInstant().toEpochMilli() ) );
        } catch ( any e ) {
            return "";
        }
    }

    /**
     * isNoIndex
     *
     * Returns whether X-Robots-Tag or a robots meta tag contains noindex or none.
     *
     * @fetchResult Fetch result containing response headers.
     * @parsedPage Optional jsoup document. Non-HTML responses omit it.
     */
    boolean function isNoIndex( required struct fetchResult, any parsedPage ) {
        if (
            fetchResult.headers.keyExists( "X-Robots-Tag" )
            && hasNoIndexToken( fetchResult.headers[ "X-Robots-Tag" ] )
        ) {
            return true;
        }

        if ( arguments.keyExists( "parsedPage" ) && !isNull( arguments.parsedPage ) ) {
            for ( var meta in arguments.parsedPage.select( "meta[name=robots]" ) ) {
                if ( hasNoIndexToken( meta.attr( "content" ) ) ) {
                    return true;
                }
            }
        }

        return false;
    }

    /**
     * hasNoIndexToken
     *
     * Returns whether a robots directive contains noindex or none. A directive
     * scoped to a named crawler also counts.
     *
     * @value Comma-separated robots directives.
     */
    private boolean function hasNoIndexToken( required string value ) {
        for ( var token in listToArray( arguments.value, "," ) ) {
            var directive = trim( token );
            // Compare the directive after an optional crawler name.
            var colonPos = directive.find( ":" );
            if ( colonPos > 0 ) {
                directive = trim( mid( directive, colonPos + 1, len( directive ) ) );
            }
            if ( directive == "noindex" || directive == "none" ) {
                return true;
            }
        }
        return false;
    }

    /**
     * getCanonicalUrl
     *
     * Returns the canonical URL from HTML or the HTTP Link header.
     *
     * @fetchResult Fetch result containing response headers.
     * @parsedPage Optional jsoup document.
     */
    string function getCanonicalUrl( required struct fetchResult, any parsedPage ) {
        // Prefer the page's canonical link.
        if ( arguments.keyExists( "parsedPage" ) ) {
            var canonical = arguments.parsedPage.select( "link[rel=canonical]" );
            if ( canonical.size() ) {
                return canonical.first().attr( "abs:href" );
            }
        }

        // Fall back to the canonical relation in the Link header.
        if ( fetchResult.headers.keyExists( "Link" ) ) {
            return findCanonicalInLinkHeader( fetchResult.headers[ "Link" ] );
        }

        return "";
    }

    /**
     * parseLinkHeader
     *
     * Splits an RFC-8288 Link header without treating commas inside URLs or
     * quoted values as separators.
     *
     * @header Raw Link header.
     * @return Entries with uri and params keys.
     */
    private array function parseLinkHeader( required string header ) {
        var entries   = [];
        var current   = "";
        var inUri     = false; // True between < and >.
        var inQuote   = false; // True inside a quoted value.
        var chars     = arguments.header;

        for ( var i = 1; i <= len( chars ); i++ ) {
            var ch = mid( chars, i, 1 );
            if ( ch == "<" && !inQuote ) {
                inUri = true;
            } else if ( ch == ">" && !inQuote ) {
                inUri = false;
            } else if ( ch == '"' ) {
                inQuote = !inQuote;
            }
            if ( ch == "," && !inUri && !inQuote ) {
                entries.append( parseLinkEntry( current ) );
                current = "";
            } else {
                current &= ch;
            }
        }
        if ( len( trim( current ) ) ) {
            entries.append( parseLinkEntry( current ) );
        }
        return entries;
    }

    /**
     * parseLinkEntry
     *
     * Parses one Link header entry into uri and params.
     *
     * @entry Entry already separated from the full header.
     */
    private struct function parseLinkEntry( required string entry ) {
        var result = { uri : "", params : {} };
        var open   = arguments.entry.find( "<" );
        var close  = arguments.entry.find( ">" );
        if ( open > 0 && close > open ) {
            result.uri = trim( mid( arguments.entry, open + 1, close - open - 1 ) );
        }

        // Parse parameters after the closing >.
        var rest = close > 0 ? mid( arguments.entry, close + 1, len( arguments.entry ) ) : "";
        for ( var part in listToArray( rest, ";" ) ) {
            var eqPos = part.find( "=" );
            if ( eqPos <= 0 ) {
                continue;
            }
            var name  = trim( part.left( eqPos - 1 ) );
            var value = trim( mid( part, eqPos + 1, len( part ) ) );
            // Remove one pair of surrounding quotes.
            if ( len( value ) >= 2 && value.startsWith( '"' ) && value.endsWith( '"' ) ) {
                value = mid( value, 2, len( value ) - 2 );
            }
            if ( len( name ) ) {
                result.params[ lCase( name ) ] = value;
            }
        }
        return result;
    }

    /**
     * findCanonicalInLinkHeader
     *
     * Returns the first URL whose Link relation contains the exact token canonical.
     *
     * @header Raw Link header.
     */
    private string function findCanonicalInLinkHeader( required string header ) {
        for ( var entry in parseLinkHeader( arguments.header ) ) {
            if ( !entry.params.keyExists( "rel" ) ) {
                continue;
            }
            for ( var rel in listToArray( entry.params.rel, " " ) ) {
                if ( compareNoCase( rel, "canonical" ) == 0 ) {
                    return entry.uri;
                }
            }
        }
        return "";
    }

    /**
     * getMetaRefreshUrl
     *
     * Returns an absolute meta-refresh target, or an empty string.
     *
     * @parsedPage jsoup document for the page.
     * @baseUrl Page URL used to resolve a relative target.
     */
    string function getMetaRefreshUrl( required any parsedPage, required string baseUrl ) {
        var meta = arguments.parsedPage.select( "meta[http-equiv=refresh]" );
        if ( !meta.size() ) {
            return "";
        }
        var content = meta.first().attr( "content" );
        // Read the value after url= with optional spaces and quotes.
        var match = reFindNoCase( "url\s*=\s*[""']?([^""']+)", content, 1, true );
        if ( match.pos.len() < 2 || match.pos[ 2 ] == 0 ) {
            return "";
        }
        var rawTarget = trim( mid( content, match.pos[ 2 ], match.len[ 2 ] ) );
        if ( !len( rawTarget ) ) {
            return "";
        }
        var absolute = resolveAgainstBase( rawTarget, arguments.baseUrl );
        if ( !len( absolute ) ) {
            logger.warn( "Could not resolve meta-refresh target '#rawTarget#' against '#arguments.baseUrl#'" );
            return "";
        }
        return cleanUrl( absolute );
    }

    /**
     * cleanUrl
     *
     * Trims and normalizes a URL before it enters crawl state.
     *
     * @url URL to clean.
     */
    string function cleanUrl( required string url ) {
        var cleaned = trim( arguments.url );          // Remove surrounding whitespace.
        cleaned = cleaned.replace( "\", "/", "all" ); // Use forward slashes.
        cleaned = reReplace( cleaned, "^(https?://[^/]+)//+", "\1/", "ALL" ); // Collapse extra path slashes.
        cleaned = cleaned.replace( " ", "%20", "all" ); // Encode spaces.
        // Remove the fragment, including #.
        var fragmentIndex = cleaned.find( "##" );
        if ( fragmentIndex > 0 ) {
            cleaned = cleaned.left( fragmentIndex - 1 );
        }
        return normalizeUrl( cleaned );
    }

    /**
     * normalizeUrl
     *
     * Lowercases the scheme and host and removes configured session parameters.
     * Path case is preserved because URL paths can be case-sensitive. Values that
     * are not absolute HTTP or HTTPS URLs are returned unchanged.
     *
     * @url URL already cleaned by cleanUrl().
     */
    private string function normalizeUrl( required string url ) {
        try {
            var urlObj   = createObject( "java", "java.net.URL" ).init( javaCast( "string", arguments.url ) );
            var protocol = urlObj.getProtocol();
            var host     = urlObj.getHost();

            // Normalize only absolute HTTP and HTTPS URLs.
            if ( ( protocol != "http" && protocol != "https" ) || !len( host ) ) {
                return arguments.url;
            }

            var userInfo = urlObj.getUserInfo(); // null when absent.
            var port     = urlObj.getPort();     // -1 when absent.
            var path     = urlObj.getPath();     // Empty when absent.
            var query    = urlObj.getQuery();    // null when absent.

            // Remove servlet session IDs from every path segment.
            path = reReplaceNoCase( path, ";jsessionid=[^/]*", "", "all" );

            var rebuilt = lCase( protocol ) & "://";
            if ( !isNull( userInfo ) && len( userInfo ) ) {
                rebuilt &= userInfo & "@";
            }
            rebuilt &= lCase( host );
            if ( port != -1 ) {
                rebuilt &= ":" & port;
            }
            rebuilt &= path;

            var cleanQuery = isNull( query ) ? "" : stripSessionParams( query );
            if ( len( cleanQuery ) ) {
                rebuilt &= "?" & cleanQuery;
            }
            return rebuilt;
        } catch ( any e ) {
            // Other filters handle relative and non-HTTP values.
            return arguments.url;
        }
    }

    /**
     * stripSessionParams
     *
     * Removes configured session and tracking parameters from a query string.
     * Parameter names are matched case-insensitively. Values are not changed.
     *
     * @query Query string without a leading ?.
     */
    private string function stripSessionParams( required string query ) {
        if ( !len( arguments.query ) ) {
            return "";
        }
        var drop = {};
        for ( var name in listToArray( settings.sessionParams ) ) {
            drop[ trim( name ) ] = true;
        }
        var kept = [];
        for ( var pair in listToArray( arguments.query, "&" ) ) {
            var eqPos    = pair.find( "=" );
            var paramKey = eqPos > 0 ? pair.left( eqPos - 1 ) : pair;
            if ( !drop.keyExists( paramKey ) ) {
                kept.append( pair );
            }
        }
        return kept.toList( "&" );
    }

    /**
     * isUrlAllowed
     *
     * Returns whether a URL uses HTTP or HTTPS, matches hostName, and does not
     * match notAllowedPattern.
     *
     * @url URL to check.
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
            return false;
        }
    }

    /**
     * isNoFollow
     *
     * Returns whether a link has a nofollow relation.
     *
     * @link jsoup link element.
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
