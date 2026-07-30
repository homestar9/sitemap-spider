<!--- Returns 404 for an image. Missing files return 500 under this mapping. --->
<cfheader statuscode="404" statustext="Not Found">
<cfcontent type="image/png">
