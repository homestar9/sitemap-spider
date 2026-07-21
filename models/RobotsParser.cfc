component accessors=true hint="Parses robots.txt content and answers allow/disallow questions" {

    /**
     * Initializes the parser to an empty rule set (allow everything).
     */
    function init() {
        resetState();
        return this;
    }

    /**
     * parse
     * Reads robots.txt content and stores the rules that apply to the given
     * user agent. Call this once per crawl; it fully resets prior state, so one
     * instance can be reused across crawls.
     *
     * Supported directives: User-agent, Disallow, Allow, Crawl-delay. Disallow
     * and Allow paths support the "*" (any sequence) and "$" (end of path)
     * wildcards, matched with longest-match precedence (on a tie, Allow wins),
     * following the Google / RFC 9309 style. Sitemap lines and "#" comments are
     * ignored.
     *
     * Not supported (documented limitations): matching against the query string
     * (path only), case-insensitive paths (paths are matched case-sensitively),
     * selecting more than one user-agent group, and the Host / Clean-param
     * directives.
     *
     * @content The raw robots.txt body. An empty string yields an allow-all rule
     *          set, which is also the graceful fallback when robots.txt is
     *          missing or unreachable.
     * @userAgent The crawler's user agent, used to pick the matching group.
     */
    void function parse( required string content, string userAgent = "*" ) {
        resetState();

        // groups[ agentToken ] = { rules: [], crawlDelay: 0 }.
        var groups = {};
        // The user-agent tokens the current rule block applies to. Consecutive
        // User-agent lines with no rule between them share the following block.
        var currentAgents = [];
        // Set to true once a rule (Disallow/Allow/Crawl-delay) is seen, so the
        // next User-agent line starts a fresh block instead of joining this one.
        var blockHasRules = false;

        // Split on CR and LF, each treated as its own delimiter, so both Unix and
        // Windows line endings work. Empty lines are dropped and skipped below.
        for ( var rawLine in listToArray( arguments.content, chr( 10 ) & chr( 13 ) ) ) {
            // Strip a trailing "##" comment and surrounding whitespace. The
            // appended "##" (a literal "#") guarantees a delimiter is present, so
            // listFirst returns the whole line when it has no comment.
            var line = trim( listFirst( rawLine & "##", "##" ) );
            if ( !len( line ) || !find( ":", line ) ) {
                continue;
            }

            var field = trim( listFirst( line, ":" ) );
            // Everything after the first ":" is the value (values can contain ":").
            var value = trim( mid( line, find( ":", line ) + 1, len( line ) ) );

            switch ( lCase( field ) ) {
                case "user-agent":
                    // A User-agent line after a rule block starts a new block.
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
                    // An empty value is a no-op: "Disallow:" means allow all.
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
                    // Sitemap and any other directive: ignore.
                    break;
            }
        }

        applyGroup( groups, arguments.userAgent );
    }

    /**
     * isPathAllowed
     * Returns whether the crawler may fetch the given path. The path should be
     * site-root-relative and start with "/". Finds every rule whose pattern
     * matches, then applies longest-match precedence: the rule with the longest
     * original pattern wins, and a tie is resolved in favor of Allow. A path with
     * no matching rule is allowed.
     *
     * @path The site-root-relative path to check (e.g. "/private/page.cfm").
     */
    boolean function isPathAllowed( required string path ) {
        var bestLength = -1;
        var allowed    = true; // no matching rule -> allowed

        for ( var rule in variables.rules ) {
            if ( reFind( rule.regex, arguments.path ) ) {
                // Longer pattern wins; on an equal-length tie, Allow wins.
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
     * Returns the Crawl-delay in seconds for the active user-agent group, or 0
     * when none was declared.
     */
    numeric function getCrawlDelay() {
        return variables.crawlDelay;
    }

    /**
     * applyGroup
     * Picks the rule set for the configured user agent and copies it into
     * instance state. Prefers a specific group whose token is a case-insensitive
     * substring of the user agent; otherwise falls back to the "*" group; if
     * neither exists, leaves the allow-all empty state.
     *
     * @groups The parsed groups keyed by user-agent token.
     * @userAgent The crawler's user agent.
     */
    private void function applyGroup( required struct groups, required string userAgent ) {
        var chosen = "";
        for ( var token in arguments.groups ) {
            if ( token == "*" ) {
                continue;
            }
            if ( len( token ) && findNoCase( token, arguments.userAgent ) ) {
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
     * Converts a robots.txt path pattern into a regular expression anchored at
     * the start. Robots patterns are prefix matches: everything after the pattern
     * is unconstrained unless the pattern ends with "$", which anchors the end.
     * "*" matches any sequence of characters. All other regex metacharacters are
     * escaped so they match literally.
     *
     * Examples:
     *   "/disallow.cfm"    -> "^/disallow\.cfm"
     *   "/private/*.cfm$"  -> "^/private/.*\.cfm$"
     *
     * @pattern The raw Disallow/Allow value.
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
                // Escape a regex metacharacter so it matches literally.
                regex &= "\" & ch;
            } else {
                regex &= ch;
            }
        }

        return "^" & regex & ( anchorEnd ? "$" : "" );
    }

    /**
     * resetState
     * Clears the active rule set back to allow-all.
     */
    private void function resetState() {
        variables.rules      = [];
        variables.crawlDelay = 0;
    }

}
