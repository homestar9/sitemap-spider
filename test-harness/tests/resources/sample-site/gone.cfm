<!--- Returns a real 404 so a spec can check how a missing page is reported.
      A file that simply does not exist returns 500 here, because the CFML engine
      handles every request under this mapping. --->
<cfheader statuscode="404" statustext="Not Found">
<cfoutput><!DOCTYPE html><html><head><title>Not Found</title></head><body>
<h1>Not Found</h1></body></html></cfoutput>
