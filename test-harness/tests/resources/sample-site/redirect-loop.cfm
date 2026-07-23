<cfscript>
    // Redirects to itself forever. Used only by the ModuleSpec hop-limit test:
    // the Jsoup backend must stop after maxRedirects hops and record the URL as
    // bad rather than following the loop endlessly. Not linked from any page, so
    // the normal crawl never reaches it. addtoken=false keeps the target clean.
    location( url = "redirect-loop.cfm", addtoken = false );
</cfscript>
