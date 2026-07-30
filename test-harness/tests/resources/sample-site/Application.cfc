component {

    this.name = "SampleApp";
    this.sessionManagement = true;
    this.setClientCookies = false;
    this.sessionTimeout = createTimeSpan(0,0,30,0); // 30 minutes
    this.applicationTimeout = createTimeSpan(0,2,0,0); // 2 hours

    /**
     * onRequestStart
     *
     * Passes the current request to ColdBox.
     */
    function onRequestStart(string targetPage) {
        request.applicationRoot = getRootPath();
        request.serverRoot = "http#( CGI.HTTPS == "on" ? 's' : '' )#://" & CGI.HTTP_HOST & "/";
        request.baseHref = request.serverRoot & right( request.applicationRoot, len( request.applicationRoot ) - 1 );
        return true; // Continue processing the request
    }


    /**
     * getRootPath
     *
     * Returns the sample site root URL.
     */
    private function getRootPath() {
        var cNested = listLen(getBaseTemplatePath(),"\") - listLen(getCurrentTemplatePath(),"\");
        var	appRootDir = cgi.script_name;
        var i = 0;
        
        for (i=0;i lte cNested;i=incrementValue(i)) {
            appRootDir = listDeleteAt(appRootDir,listLen(appRootDir, "/"),"/");
        }
        appRootDir = appRootDir & "/";
        return appRootDir;
    }

}