<cfscript>
pageTitle = "Home";
view = "views/index.cfm";
// INTENTIONAL: hreflang alternates for the task 24 xhtml:link test (one
// off-host, one x-default) and a meta description the video test needs for
// the required <video:description> field.
extraHead = '<link rel="alternate" hreflang="es" href="https://es.example.test/">'
    & '<link rel="alternate" hreflang="x-default" href="#request.baseHref#">'
    & '<meta name="description" content="Sample home page with a video.">';
</cfscript>
<cfinclude template="includes/layout.cfm">