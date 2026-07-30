<cfscript>
pageTitle = "Page without Base Href";
view = "views/noBaseHref.cfm";
// Omit <base href>. Parser must use the fetched URL to resolve relative links.
baseHref = "";
</cfscript>
<cfinclude template="includes/layout.cfm">
