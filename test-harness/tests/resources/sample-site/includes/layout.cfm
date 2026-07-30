<cfscript>
param pageTitle = "Untitled Page";
param canonicalUrl = "";
param baseHref = request.baseHref;
// Add page-specific tags to <head>. Empty means no extra tags.
param extraHead = "";
</cfscript>
<cfoutput>

    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>#pageTitle#</title>
        <cfif len( baseHref )>
            <base href="#baseHref#">
        </cfif>
        <cfif len( canonicalUrl )>
            <link rel="canonical" href="#canonicalUrl#">
        </cfif>
        <cfif len( extraHead )>
            #extraHead#
        </cfif>
        <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    </head>
    <body>
        
        <header class="mb-4">
            <cfinclude template="_nav.cfm">
        </header>
        
        <main class="mb-5">
            <cfinclude template="../#view#">
        </main>
        
        <footer>
            <cfinclude template="_footer.cfm">
        </footer>
        
        <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
        <script src="assets/js/app.js"></script>
    </body>
    </html>

</cfoutput>
