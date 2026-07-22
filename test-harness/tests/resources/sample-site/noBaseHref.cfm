<cfscript>
pageTitle = "Page without Base Href";
view = "views/noBaseHref.cfm";
// Force layout.cfm to skip the <base href> tag so this page is genuinely
// base-less: relative links here resolve only if the crawler passes the fetched
// URL as the base URI to the parser (task 17).
baseHref = "";
</cfscript>
<cfinclude template="includes/layout.cfm">