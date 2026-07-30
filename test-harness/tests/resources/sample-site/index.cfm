<cfscript>
pageTitle = "Home";
view = "views/index.cfm";
// Provide one off-host alternate, one default alternate, and a video description.
extraHead = '<link rel="alternate" hreflang="es" href="https://es.example.test/">'
    & '<link rel="alternate" hreflang="x-default" href="#request.baseHref#">'
    & '<meta name="description" content="Sample home page with a video.">';
</cfscript>
<cfinclude template="includes/layout.cfm">
