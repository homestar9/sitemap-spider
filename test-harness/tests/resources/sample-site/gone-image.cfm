<!--- Stands in for an image that returns 404. A spec references this from an
      <img src> so the asset check sees a real 404 rather than the 500 the engine
      returns for a file that is missing from disk. --->
<cfheader statuscode="404" statustext="Not Found">
<cfcontent type="image/png">
