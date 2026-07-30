<cfscript>
pageTitle = "No Index Page";
view = "views/noindex.cfm";
// noindex, follow: this page must stay out of the sitemap, but the link in its
// view must still be crawled.
extraHead = '<meta name="robots" content="noindex, follow">';
</cfscript>
<cfinclude template="includes/layout.cfm">
