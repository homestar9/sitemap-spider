<cfscript>
    // addtoken=false stops Adobe appending ?CFID/?CFTOKEN to the redirect target
    // when the app runs with setClientCookies=false, so the final URL stays clean.
    location( url = "location-new.cfm", addtoken = false );
</cfscript>