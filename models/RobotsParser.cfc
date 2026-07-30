component accessors=true hint="Parses robots.txt content and answers allow/disallow questions" {

    /**
     * init
     *
     * Resets the parser to allow every path.
     */
    function init() {
        resetState();
        return this;
    }

    /**
     * parse
     * Parses the User-agent, Disallow, Allow, and Crawl-delay directives that
     * apply to userAgent. Rules use RFC-9309 longest-match behavior; Allow wins
     * a tie. Paths are case-sensitive. Other directives are ignored.
     *
     * @content Raw robots.txt text. Empty text allows every path.
     * @userAgent Crawler user agent used to select a rule group.
     */
    void function parse( required string content, string userAgent = "*" ) {
        resetState();

        // Store rules and crawl delay by user-agent token.
        var groups = {};
        // Consecutive User-agent lines share one rule block.
        var currentAgents = [];
        // A User-agent after a rule starts a new block.
        var blockHasRules = false;

        // Accept Unix and Windows line endings.
        for ( var rawLine in listToArray( arguments.content, chr( 10 ) & chr( 13 ) ) ) {
            // Remove a trailing # comment.
            var line = trim( listFirst( rawLine & "##", "##" ) );
            if ( !len( line ) || !find( ":", line ) ) {
                continue;
            }

            var field = trim( listFirst( line, ":" ) );
            // Keep colons that appear inside the value.
            var value = trim( mid( line, find( ":", line ) + 1, len( line ) ) );

            switch ( lCase( field ) ) {
                case "user-agent":
                    // Start a new block after any rule.
                    if ( blockHasRules ) {
                        currentAgents = [];
                        blockHasRules = false;
                    }
                    currentAgents.append( value );
                    if ( !groups.keyExists( value ) ) {
                        groups[ value ] = { rules : [], crawlDelay : 0 };
                    }
                    break;

                case "disallow":
                case "allow":
                    blockHasRules = true;
                    // An empty Disallow or Allow value adds no rule.
                    if ( !len( value ) ) {
                        break;
                    }
                    for ( var agent in currentAgents ) {
                        groups[ agent ].rules.append( {
                            type    : lCase( field ),
                            length  : len( value ),
                            regex   : patternToRegex( value )
                        } );
                    }
                    break;

                case "crawl-delay":
                    blockHasRules = true;
                    if ( isNumeric( value ) ) {
                        for ( var agent in currentAgents ) {
                            groups[ agent ].crawlDelay = value;
                        }
                    }
                    break;

                default:
                    // Ignore unsupported directives.
                    break;
            }
        }

        applyGroup( groups, arguments.userAgent );
    }

    /**
     * isPathAllowed
     * Returns whether the selected rules allow a root-relative path. The longest
     * matching rule wins. Allow wins when two matching rules have equal length.
     *
     * @path Root-relative path with an optional query string.
     */
    boolean function isPathAllowed( required string path ) {
        var bestLength = -1;
        var allowed    = true; // No matching rule allows the path.

        for ( var rule in variables.rules ) {
            if ( reFind( rule.regex, arguments.path ) ) {
                // Prefer a longer rule, then Allow on a tie.
                if (
                    rule.length > bestLength ||
                    ( rule.length == bestLength && rule.type == "allow" )
                ) {
                    bestLength = rule.length;
                    allowed    = ( rule.type == "allow" );
                }
            }
        }

        return allowed;
    }

    /**
     * getCrawlDelay
     * Returns Crawl-delay for the selected user-agent group, or 0.
     */
    numeric function getCrawlDelay() {
        return variables.crawlDelay;
    }

    /**
     * applyGroup
     * Selects an exact, case-insensitive product-token group. The product token
     * ends at the first slash or space. The * group is the fallback.
     *
     * @groups Parsed groups keyed by user-agent token.
     * @userAgent Crawler user agent.
     */
    private void function applyGroup( required struct groups, required string userAgent ) {
        // Remove the version or description after the product token.
        var productToken = reReplace( arguments.userAgent, "[/ ].*$", "" );

        var chosen = "";
        for ( var token in arguments.groups ) {
            if ( token == "*" ) {
                continue;
            }
            if ( len( token ) && compareNoCase( token, productToken ) == 0 ) {
                chosen = token;
                break;
            }
        }
        if ( !len( chosen ) && arguments.groups.keyExists( "*" ) ) {
            chosen = "*";
        }
        if ( len( chosen ) ) {
            variables.rules      = arguments.groups[ chosen ].rules;
            variables.crawlDelay = arguments.groups[ chosen ].crawlDelay;
        }
    }

    /**
     * patternToRegex
     * Converts a robots.txt path pattern to a start-anchored regular expression.
     * * matches any text and a final $ anchors the end.
     *
     * @pattern Disallow or Allow path pattern.
     */
    private string function patternToRegex( required string pattern ) {
        var value = arguments.pattern;
        var anchorEnd = value.endsWith( "$" );
        if ( anchorEnd ) {
            value = value.left( len( value ) - 1 );
        }

        var regex = "";
        for ( var i = 1; i <= len( value ); i++ ) {
            var ch = mid( value, i, 1 );
            if ( ch == "*" ) {
                regex &= ".*";
            } else if ( refind( "[\\^$.|?*+()\[\]{}]", ch ) ) {
                // Match regex metacharacters literally.
                regex &= "\" & ch;
            } else {
                regex &= ch;
            }
        }

        return "^" & regex & ( anchorEnd ? "$" : "" );
    }

    /**
     * resetState
     * Clears the selected rules and crawl delay.
     */
    private void function resetState() {
        variables.rules      = [];
        variables.crawlDelay = 0;
    }

}
