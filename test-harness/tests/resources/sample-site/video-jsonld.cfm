<cfscript>
pageTitle = "JSON-LD Video Page";
view = "views/video-jsonld.cfm";
/* INTENTIONAL: a schema.org VideoObject inside a @graph array, for the task 26
   JSON-LD video test. It carries its own name and description, so the sitemap
   must use those rather than the page <title> and meta description. The mp4 and
   jpg are never fetched by the crawler. Nothing links to this page on purpose:
   adding it to the nav would change ModuleSpec's validPages list, so the spec
   reaches it through the create() seedUrls argument instead. */
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
