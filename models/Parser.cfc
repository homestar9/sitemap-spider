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


    /**
     * Parses HTML into a jSoup document.
     * @html The raw HTML to parse.
     * @baseUri The page's own URL. jsoup resolves every relative href/src against
     *   it, which is what makes link.attr( "abs:href" ) in getLinks return an
     *   absolute URL for a relative <a href>. A <base href> tag inside the HTML
     *   overrides this value, so passing the fetched URL is safe for pages that
     *   have a base tag and fixes the ones that do not. Defaults to "" (no base),
     *   which resolves relative hrefs to "".
     */
    any function parseHtml( required string html, string baseUri = "" ) {
        return jSoup.parse( arguments.html, arguments.baseUri );
    }

    /**
     * Extracts links from a page.
     * @page The jSoup document. It must have been parsed with a base URI (see
     *   parseHtml) or carry a <base href> tag, otherwise a relative href resolves
     *   to "" and is dropped by isUrlAllowed.
     *
     * Returns a struct { links, ignored }:
     *   - links: an array of crawlable, deduped, absolute URL strings.
     *   - ignored: an array of { url, reason } structs for links this page had but
     *     dropped, so the caller can see what was skipped and why. The only reason
     *     this function reports is "nofollow" (a link with rel="nofollow"). The
     *     crawler adds the other reasons ("excluded", "disallowed") later, since
     *     excludeUrls and robots.txt are Crawler concerns, not Parser ones.
     *
     * Off-host links and links matching notAllowedPattern (images, css/js,
     * mailto:, tel:) are dropped silently and are NOT reported in ignored. They
     * are not "our" links, so reporting every one of them would flood the list.
     * In-page duplicates are also dropped silently.
     *
     * The checks run in order so only on-host, allowed links can be reported as
     * nofollow: an off-host nofollow link is filtered by isUrlAllowed first and
     * never reaches the nofollow check.
     */
    struct function getLinks( required any page ) {
        var links   = [ ];
        var ignored = [ ];
        arguments.page.select( "a[href]" ).each( function( link, index ) {
            var linkUrl = cleanUrl( arguments.link.attr( "abs:href" ) );
            logger.info( "Found link: #linkUrl#" );
            if ( !isUrlAllowed( linkUrl ) ) {
                return; // off-host / image / mailto: dropped silently
            }
            if ( isNoFollow( arguments.link ) ) {
                ignored.append( { "url": linkUrl, "reason": "nofollow" } );
                return;
            }
            if ( links.find( linkUrl ) ) {
                return; // in-page duplicate: dropped silently
            }
            links.append( linkUrl );
        } );
        return { "links": links, "ignored": ignored };
    }

    /**
     * Extracts image URLs from a page for an image sitemap.
     * @page The jSoup document. It must have been parsed with a base URI (see
     *   parseHtml) or carry a <base href> tag, so a relative src resolves to an
     *   absolute URL via attr( "abs:src" ).
     *
     * Returns an array of absolute image URL strings. Unlike page links, images
     * are NOT host-filtered: an image sitemap may reference images served from a
     * CDN or another host. Empty and data: URIs are skipped, in-page duplicates
     * are dropped, and the list is capped at 1000 (Google's per-URL image limit).
     */
    array function getImages( required any page ) {
        var images = [];
        var seen   = {};
        arguments.page.select( "img[src]" ).each( function( img ) {
            // Check the raw src first: jsoup resolves an empty src="" against the
            // base URI to the page URL, so abs:src would look non-empty. A data:
            // URI is an inline image, not a fetchable URL, so skip it too.
            var rawSrc = trim( arguments.img.attr( "src" ) );
            if ( !len( rawSrc ) || left( rawSrc, 5 ) == "data:" ) {
                return;
            }
            var src = trim( arguments.img.attr( "abs:src" ) );
            if ( !len( src ) ) {
                return; // could not resolve to an absolute URL
            }
            if ( seen.keyExists( src ) || images.len() >= 1000 ) {
                return; // duplicate on this page, or past the per-URL cap
            }
            seen[ src ] = true;
            images.append( src );
        } );
        return images;
    }

    /**
     * Extracts hreflang alternate-language links from a page for the sitemap's
     * <xhtml:link> entries.
     * @page The jSoup document. It must have been parsed with a base URI (see
     *   parseHtml) or carry a <base href> tag, so a relative href resolves to an
     *   absolute URL via attr( "abs:href" ).
     *
     * Returns an array of { hreflang, href } structs, one per
     * <link rel="alternate" hreflang="..." href="..."> tag. The href is emitted
     * exactly as the page declared it (after resolving a relative value): no
     * cleanUrl() normalization, no host filter, no check that the target was
     * crawled. hreflang points at other-language versions of the page, which
     * usually live on other hosts, so filtering would defeat the feature. The
     * hreflang value is trimmed but never validated, so "x-default" passes.
     *
     * Tags with an empty hreflang or an empty href are skipped. Exact duplicate
     * hreflang+href pairs are dropped, and the list is capped at 1000 as a
     * defensive limit (same cap as getImages).
     */
    array function getAlternateLinks( required any page ) {
        var alternates = [ ];
        var seen       = { };
        arguments.page.select( "link[rel=alternate][hreflang]" ).each( function( link ) {
            var hreflang = trim( arguments.link.attr( "hreflang" ) );
            // Check the raw href first: jsoup resolves an empty href="" against
            // the base URI to the page URL, so abs:href would look non-empty.
            var rawHref = trim( arguments.link.attr( "href" ) );
            if ( !len( hreflang ) || !len( rawHref ) ) {
                return;
            }
            var href = trim( arguments.link.attr( "abs:href" ) );
            if ( !len( href ) ) {
                return; // could not resolve to an absolute URL
            }
            var pairKey = hreflang & "|" & href;
            if ( seen.keyExists( pairKey ) || alternates.len() >= 1000 ) {
                return; // duplicate pair on this page, or past the defensive cap
            }
            seen[ pairKey ] = true;
            alternates.append( { "hreflang": hreflang, "href": href } );
        } );
        return alternates;
    }

    /**
     * Extracts video metadata from a page for the sitemap's <video:video>
     * blocks.
     * @page The jSoup document. It must have been parsed with a base URI (see
     *   parseHtml) or carry a <base href> tag, so relative URLs resolve.
     *
     * Returns an array of structs, each with all five keys:
     *   { title, description, thumbnailLoc, contentLoc, playerLoc }
     *
     * Two sources are read, in order:
     *   1. Open Graph meta tags (at most one video per page). The player URL is
     *      the first non-empty of og:video:secure_url, og:video:url, og:video,
     *      and becomes playerLoc — OG video URLs are embed/player pages, and
     *      Google requires content_loc to be an actual media file.
     *   2. <video> elements, in document order. The media URL comes from the
     *      src attribute, or the first <source src> child when src is absent,
     *      and becomes contentLoc. The poster attribute is the thumbnail.
     *
     * Required text fields fall back to page-level values: og:title then
     * <title> for the title, og:description then <meta name=description> for
     * the description, og:image for a missing thumbnail.
     *
     * Google requires a thumbnail, title, description, and a content or player
     * URL per video. A candidate still missing any of those after the fallbacks
     * is dropped silently — the SitemapGenerator never validates. Duplicates
     * (same media/player URL, e.g. OG tags and a <video> tag pointing at the
     * same file) are emitted once, first occurrence wins. Capped at 100 videos
     * per page as a defensive limit.
     */
    array function getVideos( required any page ) {
        var baseUri = arguments.page.baseUri();

        // Page-level fallbacks, computed once. Title falls back from og:title
        // to the <title> tag; description from og:description to
        // <meta name=description>; the thumbnail fallback is og:image.
        var pageTitle = metaContent( arguments.page, "meta[property=og:title]" );
        if ( !len( pageTitle ) ) {
            pageTitle = trim( arguments.page.title() );
        }
        var pageDescription = metaContent( arguments.page, "meta[property=og:description]" );
        if ( !len( pageDescription ) ) {
            pageDescription = metaContent( arguments.page, "meta[name=description]" );
        }
        var pageThumbnail = resolveAgainstBase( metaContent( arguments.page, "meta[property=og:image]" ), baseUri );

        // Candidates are collected first, then validated/deduped below, so the
        // append logic lives in one place.
        var candidates = [ ];

        // Source 1: Open Graph. secure_url is preferred per the OG spec's own
        // ordering; plain og:video is the common shorthand.
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
                "playerLoc": ogUrl
            } );
        }

        // Source 2: <video> elements. HTML has no per-element title or
        // description, so those always come from the page-level fallbacks.
        for ( var element in arguments.page.select( "video" ) ) {
            // The media file: the element's own src, else its first
            // <source src> child. Raw attributes are checked before abs: ones
            // because jsoup resolves an empty src="" to the page URL.
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
                "playerLoc": ""
            } );
        }

        // Validate, dedupe, and cap. Dedupe is keyed on the media/player URL so
        // an OG tag and a <video> tag pointing at the same file emit once (the
        // OG entry wins because it was collected first).
        var videos = [ ];
        var seen   = { };
        for ( var candidate in candidates ) {
            var primaryUrl = len( candidate.contentLoc ) ? candidate.contentLoc : candidate.playerLoc;
            if (
                !len( primaryUrl )
                || !len( candidate.thumbnailLoc )
                || !len( candidate.title )
                || !len( candidate.description )
            ) {
                logger.debug( "Dropping incomplete video candidate on #baseUri#" );
                continue;
            }
            if ( seen.keyExists( primaryUrl ) || videos.len() >= 100 ) {
                continue; // duplicate on this page, or past the defensive cap
            }
            seen[ primaryUrl ] = true;
            videos.append( candidate );
        }
        return videos;
    }

    /**
     * Returns the trimmed content attribute of the first element matching the
     * selector, or "" when the page has no match.
     */
    private string function metaContent( required any page, required string selector ) {
        var found = arguments.page.select( arguments.selector );
        if ( !found.size() ) {
            return "";
        }
        return trim( found.first().attr( "content" ) );
    }

    /**
     * Resolves a possibly-relative URL string against a base URL and returns
     * the absolute form, or "" when it cannot be resolved.
     *
     * Needed because jsoup's "abs:" attribute prefix only resolves real URL
     * attributes (href, src, poster), not a URL held in a meta tag's content
     * attribute. Uses java.net.URL's two-argument constructor; an
     * already-absolute value is returned unchanged (the constructor ignores the
     * base then). With an empty base, only an already-absolute value survives.
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

        // Next try the Link header, which looks like:
        // <https://example.com/page.html>; rel="canonical"
        // A single Link header can carry several comma-separated relations, so the
        // header is tokenized and the canonical entry is found wherever it sits.
        if ( fetchResult.headers.keyExists( "Link" ) ) {
            return findCanonicalInLinkHeader( fetchResult.headers[ "Link" ] );
        }

        return "";
    }

    /**
     * Splits an HTTP Link header (RFC 8288) into its entries.
     * @header The raw Link header value.
     *
     * Returns an array of { uri, params } structs. uri is the target inside the
     * angle brackets; params is a struct of the ";name=value" parameters after it,
     * with names lowercased and any surrounding quotes stripped from values.
     *
     * The header is scanned one character at a time so a comma only separates
     * entries when it is not inside the "<...>" URI and not inside a quoted "..."
     * value. That keeps a comma in a URL (e.g. /a,b) or in a quoted parameter
     * (e.g. title="Smith, John") from splitting an entry in the wrong place.
     */
    private array function parseLinkHeader( required string header ) {
        var entries   = [];
        var current   = "";
        var inUri     = false; // between "<" and ">"
        var inQuote   = false; // inside a double-quoted value
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
     * Parses one Link header entry ("<uri>; name=value; ...") into { uri, params }.
     * @entry A single entry, already split off from the full header.
     *
     * The URI is read from between the first "<" and ">". Each ";"-separated
     * parameter after it is stored under its lowercased name, with surrounding
     * quotes removed from the value. An entry with no "<...>" yields an empty uri.
     */
    private struct function parseLinkEntry( required string entry ) {
        var result = { uri : "", params : {} };
        var open   = arguments.entry.find( "<" );
        var close  = arguments.entry.find( ">" );
        if ( open > 0 && close > open ) {
            result.uri = trim( mid( arguments.entry, open + 1, close - open - 1 ) );
        }

        // Everything after ">" is the parameter list.
        var rest = close > 0 ? mid( arguments.entry, close + 1, len( arguments.entry ) ) : "";
        for ( var part in listToArray( rest, ";" ) ) {
            var eqPos = part.find( "=" );
            if ( eqPos <= 0 ) {
                continue;
            }
            var name  = trim( part.left( eqPos - 1 ) );
            var value = trim( mid( part, eqPos + 1, len( part ) ) );
            // Strip one pair of surrounding double quotes if present.
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
     * Finds the canonical URL in a Link header, or "" when none is present.
     * @header The raw Link header value.
     *
     * Walks the tokenized entries and returns the first uri whose "rel" parameter
     * has a whitespace-separated token equal to "canonical" (case-insensitive).
     * Requiring an exact token means a value like rel="canonicalize" is not treated
     * as canonical, and rel may appear in any parameter position, not just first.
     * The returned URL is raw; the caller cleans it (see Crawler.crawlUrl).
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
     * The target is resolved against baseUrl by resolveAgainstBase, because
     * jSoup's "abs:" attribute prefix only resolves href/src attributes, not a
     * URL parsed out of the "content" attribute's string value. An
     * already-absolute target is returned unchanged.
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
        var absolute = resolveAgainstBase( rawTarget, arguments.baseUrl );
        if ( !len( absolute ) ) {
            logger.warn( "Could not resolve meta-refresh target '#rawTarget#' against '#arguments.baseUrl#'" );
            return "";
        }
        return cleanUrl( absolute );
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
     *
     * The final step applies the normalization policy (see normalizeUrl):
     * lowercase scheme + host, and strip session/tracking params. This runs last
     * so every URL that enters the crawl's dedup sets or the sitemap is already
     * normalized.
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
        return normalizeUrl( cleaned );
    }

    /**
     * Applies the crawl's URL normalization policy so the same page always maps
     * to one dedup key and one sitemap entry, and session tokens never leak into
     * recorded URLs.
     * @url A URL whose string form is already cleaned (see cleanUrl).
     *
     * What it does:
     *   - Lowercases the scheme and host (both are case-insensitive per spec).
     *   - Preserves path case (URL paths ARE case-sensitive per spec).
     *   - Keeps userinfo, port, and query values unchanged.
     *   - Strips the session/tracking params named in settings.sessionParams from
     *     the query string, and strips a ";jsessionid=..." path parameter.
     *
     * Only http and https URLs with a host are transformed. Anything java.net.URL
     * cannot parse (a relative href, mailto:, tel:, javascript:) is returned
     * unchanged, because those are filtered later by isUrlAllowed and must pass
     * through here untouched. The rebuild is idempotent, so re-normalizing an
     * already-normalized URL returns the same string.
     */
    private string function normalizeUrl( required string url ) {
        try {
            var urlObj   = createObject( "java", "java.net.URL" ).init( javaCast( "string", arguments.url ) );
            var protocol = urlObj.getProtocol();
            var host     = urlObj.getHost();

            // Only http/https URLs with a host get normalized; leave the rest as-is.
            if ( ( protocol != "http" && protocol != "https" ) || !len( host ) ) {
                return arguments.url;
            }

            var userInfo = urlObj.getUserInfo(); // null when absent
            var port     = urlObj.getPort();     // -1 when no explicit port
            var path     = urlObj.getPath();     // "" when absent
            var query    = urlObj.getQuery();    // null when absent

            // Strip a ";jsessionid=..." path parameter (servlet session token),
            // case-insensitive, from any path segment.
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
            // Not parseable as an absolute URL (relative, mailto:, tel:, ...).
            // Leave it to the other filters; return unchanged.
            return arguments.url;
        }
    }

    /**
     * Removes the session/tracking params named in settings.sessionParams from a
     * query string and returns the surviving pairs joined with "&" (or "" when
     * none survive).
     * @query The raw query string (no leading "?").
     *
     * Param names are matched case-insensitively: the drop list is a CFML struct,
     * whose keyExists() is itself case-insensitive, so "CFID" matches the "cfid"
     * key. Only the name (the part before "=") is compared; values are untouched.
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