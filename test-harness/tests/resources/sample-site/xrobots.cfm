<cfscript>
pageTitle = "X-Robots-Tag Page";
view = "views/xrobots.cfm";
</cfscript>
<!--- The noindex arrives as a response header here, not a meta tag, so the
      crawler's header-side check is what must catch it. --->
<cfheader name="X-Robots-Tag" value="noindex">
<cfinclude template="includes/layout.cfm">
