<cfscript>
pageTitle = "JSON-LD Video Page";
view = "views/video-jsonld.cfm";
/* Keep the VideoObject inside @graph and leave this page out of navigation.
   Its own name and description must override the page metadata. Specs reach
   this page through seedUrls, and the crawler does not fetch its media files. */
extraHead = '<script type="application/ld+json">'
    & '{ "@context": "https://schema.org", "@graph": ['
    & '{ "@type": "WebPage", "name": "Wrapper that is not a video" },'
    & '{ "@type": "VideoObject",'
    & ' "name": "Structured Data Clip",'
    & ' "description": "A video described only in JSON-LD.",'
    & ' "thumbnailUrl": [ "#request.baseHref#assets/img/sample.jpg" ],'
    & ' "contentUrl": "#request.baseHref#assets/video/jsonld.mp4",'
    & ' "embedUrl": "https://player.example.test/embed/42",'
    & ' "duration": "PT1M33S" } ] }'
    & '</script>';
</cfscript>
<cfinclude template="includes/layout.cfm">
