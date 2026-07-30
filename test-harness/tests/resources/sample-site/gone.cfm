<!--- Returns 404 for a page. Missing files return 500 under this mapping. --->
<cfheader statuscode="404" statustext="Not Found">
<cfoutput><!DOCTYPE html><html><head><title>Not Found</title></head><body>
<h1>Not Found</h1></body></html></cfoutput>
