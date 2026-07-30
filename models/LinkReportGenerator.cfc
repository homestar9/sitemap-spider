component
    singleton
    hint="Builds the broken link report from a crawl result"
{

    /**
     * generate
     *
     * Builds a link report from data already collected by Crawler. This method
     * does not make requests. Quoted keys preserve case during JSON serialization.
     *
     * @crawlResult Struct from Crawler.crawl().
     * @site Primary URL the crawl started from.
     * @moduleVersion Module version stamped into the file.
     * @generatedAt ISO-8601 timestamp for the report.
     * @return The report struct.
     */
    struct function generate(
        required struct crawlResult,
        string site = "",
        string moduleVersion = "",
        string generatedAt = ""
    ) {
        var broken    = buildBroken( arguments.crawlResult );
        var redirects = buildRedirects( arguments.crawlResult );
        var skipped   = buildSkipped( arguments.crawlResult );

        var pageCount  = arguments.crawlResult.keyExists( "processedUrls" ) ? arguments.crawlResult.processedUrls.len() : 0;
        var assetCount = arguments.crawlResult.keyExists( "assetsChecked" ) ? arguments.crawlResult.assetsChecked : 0;

        var brokenAssets = 0;
        for ( var entry in broken ) {
            if ( entry.kind == "asset" ) {
                brokenAssets++;
            }
        }

        return {
            "schemaVersion" : 1,
            "moduleVersion" : arguments.moduleVersion,
            "generatedAt"   : arguments.generatedAt,
            "site"          : arguments.site,
            "summary"       : {
                // Count fetched pages and checked assets.
                "checked"       : pageCount + assetCount,
                "pagesChecked"  : pageCount,
                "assetsChecked" : assetCount,
                "broken"        : broken.len(),
                "brokenAssets"  : brokenAssets,
                "redirected"    : redirects.len(),
                "skipped"       : skipped.len()
            },
            "broken"    : broken,
            "redirects" : redirects,
            "skipped"   : skipped
        };
    }

    /**
     * buildBroken
     *
     * Returns failed pages and assets sorted by severity.
     *
     * @crawlResult Struct from Crawler.crawl().
     */
    private array function buildBroken( required struct crawlResult ) {
        var out = [];
        if ( !arguments.crawlResult.keyExists( "badUrls" ) ) {
            return out;
        }

        for ( var badUrl in arguments.crawlResult.badUrls ) {
            var entry = arguments.crawlResult.badUrls[ badUrl ];
            out.append( {
                "url"              : badUrl,
                "status"           : entry.keyExists( "status" ) ? entry.status : 0,
                "reason"           : entry.keyExists( "reason" ) ? entry.reason : "unknown",
                "message"          : entry.keyExists( "message" ) ? entry.message : "",
                "kind"             : entry.keyExists( "kind" ) ? entry.kind : "page",
                "foundOn"          : entry.keyExists( "foundOn" ) ? entry.foundOn : [],
                "foundOnTruncated" : entry.keyExists( "foundOnTruncated" ) && entry.foundOnTruncated,
                "redirectChain"    : entry.keyExists( "redirectChain" ) ? entry.redirectChain : []
            } );
        }

        // List server errors first, then missing URLs, then other failures.
        out.sort( function( a, b ) {
            var rankDiff = severityRank( arguments.a.reason ) - severityRank( arguments.b.reason );
            return rankDiff != 0 ? rankDiff : compare( arguments.a.url, arguments.b.url );
        } );
        return out;
    }

    /**
     * severityRank
     *
     * Returns a failure reason's sort rank. Lower ranks appear first.
     *
     * @reason Failure category recorded by Crawler.
     */
    private numeric function severityRank( required string reason ) {
        switch ( arguments.reason ) {
            case "serverError":      return 1;
            case "notFound":         return 2;
            case "clientError":      return 3;
            case "tooManyRedirects": return 4;
            case "redirectError":    return 5;
            case "timeout":          return 6;
            case "connectionFailed": return 7;
            default:                 return 8;
        }
    }

    /**
     * buildRedirects
     *
     * Returns redirects. permanent is true for status 301 or 308.
     *
     * @crawlResult Struct from Crawler.crawl().
     */
    private array function buildRedirects( required struct crawlResult ) {
        var out = [];
        if ( !arguments.crawlResult.keyExists( "redirects" ) ) {
            return out;
        }

        for ( var redirect in arguments.crawlResult.redirects ) {
            var status = redirect.keyExists( "status" ) ? redirect.status : 0;
            out.append( {
                "from"             : redirect.from,
                "to"               : redirect.to,
                "status"           : status,
                "permanent"        : status == 301 || status == 308,
                "chain"            : redirect.keyExists( "chain" ) ? redirect.chain : [],
                "foundOn"          : redirect.keyExists( "foundOn" ) ? redirect.foundOn : [],
                "foundOnTruncated" : redirect.keyExists( "foundOnTruncated" ) && redirect.foundOnTruncated
            } );
        }

        // List permanent redirects first, then sort by source URL.
        out.sort( function( a, b ) {
            if ( arguments.a.permanent != arguments.b.permanent ) {
                return arguments.a.permanent ? -1 : 1;
            }
            return compare( arguments.a.from, arguments.b.from );
        } );
        return out;
    }

    /**
     * buildSkipped
     *
     * Returns skipped URLs and their reasons.
     *
     * @crawlResult Struct from Crawler.crawl().
     */
    private array function buildSkipped( required struct crawlResult ) {
        var out = [];
        if ( !arguments.crawlResult.keyExists( "ignored" ) ) {
            return out;
        }
        for ( var ignored in arguments.crawlResult.ignored ) {
            out.append( { "url": ignored.url, "reason": ignored.reason } );
        }
        // Group by reason, then sort each group by URL.
        out.sort( function( a, b ) {
            var reasonDiff = compare( arguments.a.reason, arguments.b.reason );
            return reasonDiff != 0 ? reasonDiff : compare( arguments.a.url, arguments.b.url );
        } );
        return out;
    }

}
